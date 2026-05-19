use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

/// One entry in `<scope>/.vstack-source.json`. Records where a package was
/// copied from so update detection can compare installed vs source versions.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceIndexEntry {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_repo: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_commit: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub installed_at: Option<u64>,
}

pub type SourceIndex = BTreeMap<String, SourceIndexEntry>;

/// Read the source index for the chosen scope. Missing file is treated as
/// empty. Parse failures return an error so the user can fix the file rather
/// than silently lose tracking data.
pub fn read_source_index(global: bool) -> Result<SourceIndex> {
    let path = crate::config::pi_source_index_path(global);
    if !path.exists() {
        return Ok(SourceIndex::new());
    }
    let raw =
        std::fs::read_to_string(&path).with_context(|| format!("reading {}", path.display()))?;
    let parsed: SourceIndex =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", path.display()))?;
    Ok(parsed)
}

/// Persist the source index for the chosen scope, creating parent dirs as
/// needed. Empty index removes the file so we don't leave dangling state.
pub fn write_source_index(global: bool, index: &SourceIndex) -> Result<()> {
    let path = crate::config::pi_source_index_path(global);
    if index.is_empty() {
        if path.exists() {
            std::fs::remove_file(&path)?;
        }
        return Ok(());
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let pretty = serde_json::to_string_pretty(index)?;
    std::fs::write(&path, pretty)?;
    Ok(())
}

/// Inspect a Pi `settings.json` packages array and return the entries that
/// resolve to npm specifiers (`npm:<name>` or `npm:<name>@<version>`).
/// Returns the bare package name (without version tag).
pub fn list_npm_packages(global: bool) -> Result<Vec<String>> {
    let settings_path = crate::config::pi_settings_path(global);
    if !settings_path.exists() {
        return Ok(Vec::new());
    }
    let raw = std::fs::read_to_string(&settings_path)
        .with_context(|| format!("reading {}", settings_path.display()))?;
    let parsed: serde_json::Value = serde_json::from_str(&raw)
        .with_context(|| format!("parsing {}", settings_path.display()))?;
    let packages = parsed
        .get("packages")
        .and_then(|p| p.as_array())
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for entry in packages {
        if let Some(s) = entry.as_str()
            && let Some(rest) = s.strip_prefix("npm:")
        {
            // Strip version tag (`pkg@1.2.3` or `@scope/pkg@1.2.3`).
            let bare = if let Some(rest_no_scope) = rest.strip_prefix('@') {
                // Scoped: keep `@scope/pkg`, drop trailing `@<version>` if any.
                match rest_no_scope.find('@') {
                    Some(idx) => format!("@{}", &rest_no_scope[..idx]),
                    None => format!("@{}", rest_no_scope),
                }
            } else {
                rest.split('@').next().unwrap_or(rest).to_string()
            };
            if !bare.is_empty() {
                out.push(bare);
            }
        }
    }
    Ok(out)
}

/// List vstack-copied packages installed in the chosen scope by reading the
/// packages directory. These are directories with a `package.json` (npm-style)
/// that vstack copied from a source repo.
///
/// Walks one extra level into npm-scope dirs (names starting with `@`) so
/// scoped packages like `@vanillagreen/pi-foo` are reported as
/// `@vanillagreen/pi-foo`, matching their lock-entry and source-index keys.
/// Without this, every scoped install looks uninstalled to update-pi.
pub fn list_installed_vstack_packages(global: bool) -> Vec<String> {
    let dir = crate::config::pi_packages_dir(global);
    let Ok(entries) = std::fs::read_dir(&dir) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let Some(file_name) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        if file_name.starts_with('@') {
            // npm scope dir; recurse one level for `@scope/pkg` entries.
            let Ok(sub_entries) = std::fs::read_dir(&path) else {
                continue;
            };
            for sub in sub_entries.flatten() {
                let sub_path = sub.path();
                if !sub_path.is_dir() || !sub_path.join("package.json").exists() {
                    continue;
                }
                if let Some(sub_name) = sub_path.file_name().and_then(|n| n.to_str()) {
                    names.push(format!("{file_name}/{sub_name}"));
                }
            }
            continue;
        }
        if !path.join("package.json").exists() {
            continue;
        }
        names.push(file_name.to_string());
    }
    names.sort();
    names
}

/// A Pi package discovered under `pi-extensions/<name>/`.
///
/// Pi packages are npm-shaped. We surface the subset of `package.json`
/// that vstack actually uses to display, install, and register the
/// package with Pi.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiExtension {
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub keywords: Vec<String>,
    /// `pi.extensions` from package.json — the relative paths Pi loads.
    #[serde(default)]
    pub pi_extensions: Vec<String>,
    /// `bin` map from package.json. Names → relative script paths.
    #[serde(default)]
    pub bin: std::collections::BTreeMap<String, String>,
    /// `pi.appendSystem` from package.json — relative path to a markdown
    /// file whose contents are upserted into the scope's `APPEND_SYSTEM.md`
    /// on install (and removed on uninstall) so models get extension-
    /// specific tool-usage guidance even without per-call hook plumbing.
    #[serde(default)]
    pub append_system: Option<String>,
    /// Directory containing the package's `package.json`.
    #[serde(skip)]
    pub source_dir: PathBuf,
}

#[derive(Debug, Deserialize)]
struct RawPackage {
    name: String,
    #[serde(default)]
    description: String,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    keywords: Vec<String>,
    #[serde(default)]
    pi: Option<PiManifest>,
    #[serde(default)]
    bin: Option<BinField>,
}

#[derive(Debug, Deserialize)]
struct PiManifest {
    #[serde(default)]
    extensions: Vec<String>,
    #[serde(default, rename = "appendSystem")]
    append_system: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(untagged)]
enum BinField {
    /// `"bin": "./bin/foo.js"` — implicit name = package name.
    Single(String),
    /// `"bin": { "foo": "./bin/foo.js" }`.
    Map(std::collections::BTreeMap<String, String>),
}

impl PiExtension {
    /// Parse a Pi package manifest at `pi-extensions/<name>/package.json`.
    pub fn from_dir(dir: &Path) -> Result<Self> {
        let pkg_path = dir.join("package.json");
        let raw = std::fs::read_to_string(&pkg_path)
            .with_context(|| format!("reading {}", pkg_path.display()))?;
        let parsed: RawPackage = serde_json::from_str(&raw)
            .with_context(|| format!("parsing {}", pkg_path.display()))?;

        let (pi_extensions, append_system) = parsed
            .pi
            .map(|m| (m.extensions, m.append_system))
            .unwrap_or_default();

        let bin = match parsed.bin {
            Some(BinField::Single(path)) => {
                let mut map = std::collections::BTreeMap::new();
                map.insert(parsed.name.clone(), path);
                map
            }
            Some(BinField::Map(map)) => map,
            None => std::collections::BTreeMap::new(),
        };

        Ok(PiExtension {
            name: parsed.name,
            description: parsed.description,
            version: parsed.version,
            keywords: parsed.keywords,
            pi_extensions,
            bin,
            append_system,
            source_dir: dir.to_path_buf(),
        })
    }
}

/// Discover Pi packages in `<source>/pi-extensions/<name>/package.json`.
pub fn discover_pi_extensions(dir: &Path) -> Result<Vec<PiExtension>> {
    let mut out = Vec::new();
    if !dir.exists() {
        return Ok(out);
    }
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        if !path.join("package.json").exists() {
            continue;
        }
        match PiExtension::from_dir(&path) {
            Ok(ext) => out.push(ext),
            Err(e) => eprintln!("Warning: skipping {}: {e}", path.display()),
        }
    }
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}

/// Package renames shipped by vstack. Pi de-duplicates packages by identity,
/// not by the resources they register, so a renamed package can leave a legacy
/// package behind that registers the same tool/command and crashes Pi startup.
///
/// 1.0.0 release moved every package under the `@vanillagreen/` scope so they
/// could be published to npm without colliding with unrelated unscoped names.
/// Stale locks pre-dating the move still key on the unscoped names, so each
/// scoped name lists its unscoped predecessor (and any earlier aliases).
const PI_EXTENSION_RENAMES: &[(&str, &[&str])] = &[
    (
        "@vanillagreen/pi-agents-tmux",
        &["pi-agents-tmux", "pi-subagents-tmux", "pi-subagents"],
    ),
    (
        "@vanillagreen/pi-background-tasks",
        &["pi-background-tasks"],
    ),
    ("@vanillagreen/pi-caveman", &["pi-caveman"]),
    ("@vanillagreen/pi-claude-bridge", &["pi-claude-bridge"]),
    (
        "@vanillagreen/pi-codex-minimal-tools",
        &["pi-codex-minimal-tools"],
    ),
    (
        "@vanillagreen/pi-extension-manager",
        &["pi-extension-manager"],
    ),
    ("@vanillagreen/pi-flightdeck", &["pi-flightdeck"]),
    ("@vanillagreen/pi-hooks", &["pi-hooks"]),
    ("@vanillagreen/pi-output-policy", &["pi-output-policy"]),
    (
        "@vanillagreen/pi-prompt-stash",
        &["pi-prompt-stash", "prompt-stash"],
    ),
    ("@vanillagreen/pi-qol", &["pi-qol"]),
    ("@vanillagreen/pi-questions", &["pi-questions"]),
    ("@vanillagreen/pi-session-bridge", &["pi-session-bridge"]),
    ("@vanillagreen/pi-session-manager", &["pi-session-manager"]),
    ("@vanillagreen/pi-skills-manager", &["pi-skills-manager"]),
    ("@vanillagreen/pi-task-panel", &["pi-task-panel"]),
    ("@vanillagreen/pi-tool-renderer", &["pi-tool-renderer"]),
    ("@vanillagreen/pi-web-tools", &["pi-web-tools"]),
];

/// Legacy package names that should be removed from the same scope before the
/// current package is installed.
pub fn legacy_names_for(name: &str) -> &'static [&'static str] {
    PI_EXTENSION_RENAMES
        .iter()
        .find_map(|(current, legacy)| (*current == name).then_some(*legacy))
        .unwrap_or(&[])
}

/// Does the package appear to be installed in the given Pi scope?
///
/// This checks both the deployed package directory and `settings.json`, so it
/// also catches stale settings entries left after manual deletion.
pub fn is_pi_extension_installed(name: &str, global: bool) -> bool {
    let dest = crate::config::pi_packages_dir(global).join(name);
    dest.exists()
        || dest.is_symlink()
        || settings_references_package(name, &dest, global).unwrap_or(false)
}

fn settings_references_package(name: &str, dest: &Path, global: bool) -> Result<bool> {
    let settings_path = crate::config::pi_settings_path(global);
    if !settings_path.exists() {
        return Ok(false);
    }
    let settings = load_or_init_settings(&settings_path)?;
    Ok(settings
        .get("packages")
        .and_then(|p| p.as_array())
        .is_some_and(|packages| {
            packages
                .iter()
                .any(|e| entry_matches_package(e, name, dest))
        }))
}

fn remove_same_scope_legacy_packages(name: &str, global: bool) -> Result<()> {
    for legacy in legacy_names_for(name) {
        if !is_pi_extension_installed(legacy, global) {
            continue;
        }

        let removed = remove_pi_extension(legacy, global)?;
        let scope_label = if global { "global" } else { "project" };
        if removed.is_empty() {
            eprintln!("  Migrated legacy pi-package {legacy} → {name} ({scope_label} scope)");
        } else {
            let removed_list = removed
                .iter()
                .map(|p| p.display().to_string())
                .collect::<Vec<_>>()
                .join(", ");
            eprintln!(
                "  Migrated legacy pi-package {legacy} → {name} ({scope_label} scope): removed {removed_list}"
            );
        }
    }
    Ok(())
}

/// Install a Pi package into the chosen scope.
///
/// Steps:
/// 1. Remove any same-scope vstack legacy package names for this package
///    (for example `pi-subagents-tmux` → `pi-agents-tmux`). Renamed Pi
///    packages can register the same tools, and Pi treats them as distinct
///    packages, so leaving the legacy package installed crashes startup.
/// 2. If the SAME extension (or one of its legacy names) is already installed
///    at the OTHER scope, SKIP the install with a notice. Pi loads packages
///    from BOTH global and project scopes; duplicate resources cause
///    "Tool X conflicts with Y" errors at Pi startup. The existing scope wins
///    — to switch scopes, the user explicitly runs
///    `vstack remove [--global] <name>` then re-installs at the desired scope.
/// 3. Copy the package directory into `<scope>/packages/<name>/`.
/// 4. If `package.json` declares production dependencies, run `npm install`
///    in the deployed package directory so Pi can resolve runtime modules.
/// 5. For every entry in the package.json `bin` field, create a symlink
///    at `<scope>/bin/<cli-name>` pointing at the installed binary.
/// 6. Add a relative path entry (`./packages/<name>`) to Pi's `settings.json`
///    `packages` array, preserving any existing entries.
///
/// Pi resolves relative path entries against the settings file directory:
/// - `~/.pi/agent/settings.json` → `~/.pi/agent`
/// - `<project>/.pi/settings.json` → `<project>/.pi`
///
/// Both layouts use the same `./packages/<name>` shape.
///
/// Returns `Ok(None)` when the install was skipped due to a cross-scope
/// duplicate; callers can use this to omit the entry from the lock file
/// summary so vstack's view of state stays accurate.
pub fn install_pi_extension(ext: &PiExtension, global: bool) -> Result<Option<PathBuf>> {
    // Step 1: same-scope legacy migration for package renames. This is safe to
    // do automatically because these are vstack-owned package names and the new
    // package supersedes the old one.
    remove_same_scope_legacy_packages(&ext.name, global)?;

    // Step 2a: cross-scope guard for the same current package name. Pi loads
    // from both scopes — duplicate registration would crash startup. Existing
    // scope is authoritative.
    if is_pi_extension_installed(&ext.name, !global) {
        let this_label = if global { "global" } else { "project" };
        let other_label = if global { "project" } else { "global" };
        eprintln!(
            "  Skip pi-package {} ({this_label} install): already installed at {other_label} scope. Run `vstack remove {}{}` first to switch.",
            ext.name,
            if !global { "--global " } else { "" },
            ext.name,
        );
        return Ok(None);
    }

    // Step 2b: cross-scope guard for legacy package names. We migrate the
    // selected scope automatically, but do not delete packages from the other
    // scope as a side effect of this install.
    for legacy in legacy_names_for(&ext.name) {
        if is_pi_extension_installed(legacy, !global) {
            let this_label = if global { "global" } else { "project" };
            let other_label = if global { "project" } else { "global" };
            eprintln!(
                "  Skip pi-package {} ({this_label} install): legacy package {legacy} is installed at {other_label} scope and registers the same resources. Run `vstack remove {}{legacy}` first.",
                ext.name,
                if !global { "--global " } else { "" },
            );
            return Ok(None);
        }
    }

    let dest_dir = crate::config::pi_packages_dir(global);
    std::fs::create_dir_all(&dest_dir)?;
    let dest = dest_dir.join(&ext.name);

    // Idempotent reinstall: clear any prior copy. NotFound is fine; other
    // errors (EACCES etc.) propagate so we don't copy onto a broken state.
    clear_path(&dest)?;

    copy_dir(&ext.source_dir, &dest)?;
    install_production_dependencies_if_needed(&ext.name, &dest)?;
    install_bin_links(ext, &dest, global)?;
    register_in_pi_settings(&ext.name, &dest, global)?;
    let _ = update_source_index(ext, global);
    let _ = install_append_system_for(ext, &dest, global);

    Ok(Some(dest))
}

/// Walk up from a package's source dir to find the vstack repo root.
/// Identified by presence of a top-level `pi-extensions/` sibling and a
/// `Cargo.toml` or `.git` marker. Returns None if not found.
fn find_vstack_repo_root(source_dir: &Path) -> Option<PathBuf> {
    let mut dir = source_dir.to_path_buf();
    while dir.pop() {
        if dir.join("pi-extensions").is_dir()
            && (dir.join("Cargo.toml").exists()
                || dir.join(".git").exists()
                || dir.join("vstack.toml").exists())
        {
            return Some(dir);
        }
    }
    None
}

/// Read current HEAD sha of a git repo (best-effort, optional).
fn read_git_head(repo: &Path) -> Option<String> {
    let out = std::process::Command::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(repo)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if s.is_empty() { None } else { Some(s) }
}

/// Append/replace this package's entry in the scope's `.vstack-source.json`.
/// Records the source repo path, source version at install time, and a git
/// sha if available so the extension manager can detect updates.
fn update_source_index(ext: &PiExtension, global: bool) -> Result<()> {
    // Tolerate a corrupt index here so install never fails on tracking data.
    let mut index = read_source_index(global).unwrap_or_default();
    let repo_root = find_vstack_repo_root(&ext.source_dir);
    let repo_str = repo_root
        .as_ref()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| ext.source_dir.to_string_lossy().to_string());
    let sha = repo_root.as_deref().and_then(read_git_head);
    let installed_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .ok();

    index.insert(
        ext.name.clone(),
        SourceIndexEntry {
            source_repo: Some(repo_str),
            source_path: Some(ext.source_dir.to_string_lossy().to_string()),
            source_version: ext.version.clone(),
            source_commit: sha,
            installed_at,
        },
    );
    write_source_index(global, &index)
}

/// Drop a package's entry from the scope's source index. Best-effort: a
/// missing index file or missing entry is fine.
fn remove_from_source_index(name: &str, global: bool) -> Result<()> {
    let mut index = match read_source_index(global) {
        Ok(idx) => idx,
        Err(_) => return Ok(()),
    };
    if index.remove(name).is_none() {
        return Ok(());
    }
    write_source_index(global, &index)
}

/// Remove a Pi package, its bin symlinks, and its settings entry.
pub fn remove_pi_extension(name: &str, global: bool) -> Result<Vec<PathBuf>> {
    let mut removed = Vec::new();
    let dest = crate::config::pi_packages_dir(global).join(name);

    // Read package.json BEFORE deleting the dir so we know which bin
    // symlinks to clean up. Best-effort: if the package.json is gone or
    // unreadable, skip bin cleanup rather than failing the whole remove.
    if dest.is_dir()
        && let Ok(ext) = PiExtension::from_dir(&dest)
    {
        for cli_name in ext.bin.keys() {
            let link = crate::config::pi_bin_dir(global).join(cli_name);
            match std::fs::remove_file(&link) {
                Ok(()) => removed.push(link),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => return Err(e.into()),
            }
        }
    }

    // NotFound is expected when the package isn't installed.
    if clear_path(&dest)? {
        removed.push(dest.clone());
    }
    if unregister_from_pi_settings(name, &dest, global)? {
        removed.push(crate::config::pi_settings_path(global));
    }
    let _ = remove_from_source_index(name, global);
    match remove_append_system_for(name, global) {
        Ok(AppendSystemRemoveOutcome::Updated | AppendSystemRemoveOutcome::Deleted) => {
            removed.push(append_system_path(global));
        }
        Ok(AppendSystemRemoveOutcome::NoOp) | Err(_) => {}
    }
    Ok(removed)
}

/// Create symlinks at `<scope>/bin/<cli-name>` for every entry in the
/// package's `bin` field. Existing files at the link path are removed
/// first (idempotent re-install). Absolute targets so the symlink keeps
/// resolving even if relative pathing is fragile.
fn install_bin_links(ext: &PiExtension, package_dest: &Path, global: bool) -> Result<()> {
    if ext.bin.is_empty() {
        return Ok(());
    }
    let bin_dir = crate::config::pi_bin_dir(global);
    std::fs::create_dir_all(&bin_dir)?;
    for (cli_name, rel_target) in &ext.bin {
        let target = package_dest.join(rel_target);
        if !target.exists() {
            eprintln!(
                "  Warning: skip bin link {cli_name} → {} (target missing)",
                target.display()
            );
            continue;
        }
        let link = bin_dir.join(cli_name);
        let _ = std::fs::remove_file(&link);
        #[cfg(unix)]
        std::os::unix::fs::symlink(&target, &link)
            .with_context(|| format!("symlinking bin {} → {}", link.display(), target.display()))?;
    }
    Ok(())
}

/// The canonical `packages` entry vstack writes for a given package name.
fn relative_settings_entry(name: &str) -> String {
    format!("./packages/{}", name)
}

/// True if a `packages` entry refers to our package — matches:
/// - the canonical relative form (`./packages/<name>`)
/// - the legacy absolute path we used to write
/// - either form wrapped in a `{ "source": ... }` object
fn entry_matches_package(entry: &serde_json::Value, name: &str, absolute_dest: &Path) -> bool {
    let canonical = relative_settings_entry(name);
    let absolute = absolute_dest.to_string_lossy();
    let matches_str = |s: &str| s == canonical || s == absolute.as_ref();
    match entry {
        serde_json::Value::String(s) => matches_str(s),
        serde_json::Value::Object(obj) => obj
            .get("source")
            .and_then(|v| v.as_str())
            .is_some_and(matches_str),
        _ => false,
    }
}

/// Add a relative `./packages/<name>` entry to the `packages` array of Pi's
/// `settings.json` for the scope, preserving every other entry.
///
/// Dedupe also recognizes the absolute-path form previously written by
/// vstack so re-installs don't leave a stale duplicate behind.
fn register_in_pi_settings(name: &str, dest: &Path, global: bool) -> Result<()> {
    let settings_path = crate::config::pi_settings_path(global);
    if let Some(parent) = settings_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut settings = load_or_init_settings(&settings_path)?;
    let entry = relative_settings_entry(name);

    let map = settings
        .as_object_mut()
        .context("Pi settings.json is not a JSON object")?;
    if !map.contains_key("packages") {
        map.insert("packages".into(), serde_json::json!([]));
    }
    let packages = map
        .get_mut("packages")
        .and_then(|p| p.as_array_mut())
        .context("Pi settings.json `packages` is not an array")?;

    // Replace any existing entry for this package in place so reinstalling a
    // package does not change Pi extension load order. This matters when two
    // packages both customize the same UI surface (for example the editor).
    // Dedupe also recognizes legacy absolute-path entries and object forms.
    let mut replacement_index = None;
    let mut next_packages = Vec::with_capacity(packages.len() + 1);
    for existing in packages.drain(..) {
        if entry_matches_package(&existing, name, dest) {
            if replacement_index.is_none() {
                replacement_index = Some(next_packages.len());
            }
            continue;
        }
        next_packages.push(existing);
    }

    let replacement = serde_json::Value::String(entry);
    if let Some(index) = replacement_index {
        next_packages.insert(index, replacement);
    } else {
        next_packages.push(replacement);
    }
    *packages = next_packages;

    write_settings(&settings_path, &settings)
}

/// Remove the settings entry for `name` (matches relative or absolute form).
/// Returns true when `settings.json` changed.
fn unregister_from_pi_settings(name: &str, dest: &Path, global: bool) -> Result<bool> {
    let settings_path = crate::config::pi_settings_path(global);
    if !settings_path.exists() {
        return Ok(false);
    }
    let mut settings = load_or_init_settings(&settings_path)?;
    let Some(map) = settings.as_object_mut() else {
        return Ok(false);
    };

    let mut changed = false;
    if let Some(packages) = map.get_mut("packages").and_then(|p| p.as_array_mut()) {
        let before = packages.len();
        packages.retain(|entry| !entry_matches_package(entry, name, dest));
        changed = packages.len() != before;
        if packages.is_empty() {
            map.remove("packages");
            changed = true;
        }
    }

    if changed {
        write_settings(&settings_path, &settings)?;
    }
    Ok(changed)
}

fn load_or_init_settings(path: &Path) -> Result<serde_json::Value> {
    if !path.exists() {
        return Ok(serde_json::json!({}));
    }
    let content =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    if content.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    serde_json::from_str(&content)
        .with_context(|| format!("parsing Pi settings {}", path.display()))
}

fn write_settings(path: &Path, value: &serde_json::Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let pretty = serde_json::to_string_pretty(value)?;
    std::fs::write(path, pretty)?;
    Ok(())
}

/// Remove `path` whether it's a file, symlink, or directory. Returns
/// `Ok(true)` if something was removed, `Ok(false)` if it didn't exist.
/// Other errors (permissions, IO) propagate.
fn clear_path(path: &Path) -> std::io::Result<bool> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) => {
            if meta.is_dir() {
                std::fs::remove_dir_all(path)?;
            } else {
                std::fs::remove_file(path)?;
            }
            Ok(true)
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(e),
    }
}

const COPY_DIR_SKIP_NAMES: &[&str] = &[
    "node_modules",
    ".git",
    ".turbo",
    ".next",
    ".cache",
    "build",
    "out",
    "coverage",
    ".pi",
    // Integration-test scratch dir (pi-claude-bridge). Gitignored, not in
    // any package's `files` field. Must stay in sync with the hash-skip
    // sets in config::should_skip_hash_dir / verify::should_skip_hash_dir.
    ".test-output",
];

fn should_skip_copy_entry(name: &str) -> bool {
    COPY_DIR_SKIP_NAMES.contains(&name)
}

const NPM_PRODUCTION_INSTALL_ARGS: &[&str] = &[
    "install",
    "--omit=dev",
    "--package-lock=false",
    "--legacy-peer-deps",
    "--no-audit",
    "--no-fund",
];

#[cfg(test)]
static NPM_COMMAND_OVERRIDE: std::sync::Mutex<Option<PathBuf>> = std::sync::Mutex::new(None);

fn npm_command() -> PathBuf {
    #[cfg(test)]
    {
        let guard = match NPM_COMMAND_OVERRIDE.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(command) = guard.as_ref() {
            return command.clone();
        }
    }
    PathBuf::from("npm")
}

fn manifest_object_field_non_empty(manifest: &serde_json::Value, key: &str) -> bool {
    manifest
        .get(key)
        .and_then(|v| v.as_object())
        .is_some_and(|map| !map.is_empty())
}

fn package_declares_runtime_dependencies(package_dir: &Path) -> Result<bool> {
    let manifest = package_dir.join("package.json");
    let raw = std::fs::read_to_string(&manifest)
        .with_context(|| format!("reading {}", manifest.display()))?;
    let parsed: serde_json::Value =
        serde_json::from_str(&raw).with_context(|| format!("parsing {}", manifest.display()))?;
    Ok(manifest_object_field_non_empty(&parsed, "dependencies")
        || manifest_object_field_non_empty(&parsed, "optionalDependencies"))
}

fn shell_quote_path(path: &Path) -> String {
    let raw = path.to_string_lossy();
    format!("'{}'", raw.replace('\'', "'\\''"))
}

fn npm_production_install_command(package_dir: &Path) -> String {
    format!(
        "cd {} && npm {}",
        shell_quote_path(package_dir),
        NPM_PRODUCTION_INSTALL_ARGS.join(" ")
    )
}

fn install_production_dependencies_if_needed(package_name: &str, package_dir: &Path) -> Result<()> {
    if !package_declares_runtime_dependencies(package_dir)? {
        return Ok(());
    }

    let recovery = npm_production_install_command(package_dir);
    let command = npm_command();
    let output = Command::new(&command)
        .args(NPM_PRODUCTION_INSTALL_ARGS)
        .current_dir(package_dir)
        .stdin(Stdio::null())
        .output()
        .with_context(|| {
            format!(
                "pi-package {package_name} declares production dependencies, but npm could not run. Recovery: `{recovery}`"
            )
        })?;

    if !output.status.success() {
        let mut details = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if details.is_empty() {
            details = String::from_utf8_lossy(&output.stdout).trim().to_string();
        }
        if details.is_empty() {
            details = output.status.to_string();
        }
        anyhow::bail!(
            "pi-package {package_name} declares production dependencies, but `npm install` failed in {}: {details}. Recovery: `{recovery}`",
            package_dir.display()
        );
    }

    Ok(())
}

/// Path to the scope's `APPEND_SYSTEM.md`. Pi reads global from
/// `<pi_global_dir>/APPEND_SYSTEM.md` (where pi_global_dir respects
/// `PI_CODING_AGENT_DIR`) and project from `<project>/.pi/APPEND_SYSTEM.md`,
/// matching pi-claude-bridge `prompt-context.ts`. Both layouts share the
/// scope root with `packages/`, so the same shape works in both scopes.
pub fn append_system_path(global: bool) -> PathBuf {
    if global {
        crate::config::pi_global_dir().join("APPEND_SYSTEM.md")
    } else {
        crate::config::pi_project_dir().join("APPEND_SYSTEM.md")
    }
}

fn append_system_block_markers(name: &str) -> (String, String) {
    (
        format!("<!-- vstack:append-system {name} begin -->"),
        format!("<!-- vstack:append-system {name} end -->"),
    )
}

fn append_system_strip_block(existing: &str, begin: &str, end: &str) -> String {
    // Splice the begin..end span out of `existing` without touching the
    // surrounding newlines. The collapse pass below normalizes any
    // resulting 3+ consecutive newlines down to one blank line so a
    // sandwiched block doesn't leave a gap when removed.
    let mut out = String::with_capacity(existing.len());
    let mut rest = existing;
    while let Some(start) = rest.find(begin) {
        out.push_str(&rest[..start]);
        let after = &rest[start + begin.len()..];
        match after.find(end) {
            Some(end_idx) => {
                rest = &after[end_idx + end.len()..];
            }
            None => {
                // Unterminated marker — leave it alone rather than risk
                // dropping unrelated content.
                out.push_str(begin);
                rest = after;
                break;
            }
        }
    }
    out.push_str(rest);

    let mut collapsed = String::with_capacity(out.len());
    let mut prev_nl = 0;
    for ch in out.chars() {
        if ch == '\n' {
            prev_nl += 1;
            if prev_nl > 2 {
                continue;
            }
        } else {
            prev_nl = 0;
        }
        collapsed.push(ch);
    }
    collapsed
        .trim_start_matches('\n')
        .trim_end_matches('\n')
        .to_string()
}

/// Insert or replace the named block in `target` and return whether the
/// file changed. Block boundaries use HTML comment markers so the file
/// stays valid markdown. Creates the file (and parent dir) if missing.
pub fn append_system_upsert(target: &Path, name: &str, content: &str) -> Result<bool> {
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Ok(matches!(
            append_system_remove(target, name)?,
            AppendSystemRemoveOutcome::Updated | AppendSystemRemoveOutcome::Deleted
        ));
    }
    let (begin, end) = append_system_block_markers(name);
    let block = format!("{begin}\n{trimmed}\n{end}");

    let existing = match std::fs::read_to_string(target) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e.into()),
    };
    let stripped = append_system_strip_block(&existing, &begin, &end);
    let next = if stripped.is_empty() {
        format!("{block}\n")
    } else {
        format!("{stripped}\n\n{block}\n")
    };
    if next == existing {
        return Ok(false);
    }
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(target, &next).with_context(|| format!("writing {}", target.display()))?;
    Ok(true)
}

/// Outcome of removing a named block from an APPEND_SYSTEM.md file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppendSystemRemoveOutcome {
    /// File missing or block not present — no change.
    NoOp,
    /// Block removed; file still has other content.
    Updated,
    /// Block removed; the file would be empty so it was deleted.
    Deleted,
}

/// Remove the named block from `target` if present. Missing file is a
/// no-op. When removing the block leaves an empty file, delete the file
/// rather than leaving an empty placeholder behind.
pub fn append_system_remove(target: &Path, name: &str) -> Result<AppendSystemRemoveOutcome> {
    let existing = match std::fs::read_to_string(target) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(AppendSystemRemoveOutcome::NoOp);
        }
        Err(e) => return Err(e.into()),
    };
    let (begin, end) = append_system_block_markers(name);
    if !existing.contains(&begin) {
        return Ok(AppendSystemRemoveOutcome::NoOp);
    }
    let stripped = append_system_strip_block(&existing, &begin, &end);
    if stripped.is_empty() {
        match std::fs::remove_file(target) {
            Ok(()) => Ok(AppendSystemRemoveOutcome::Deleted),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                Ok(AppendSystemRemoveOutcome::Deleted)
            }
            Err(e) => Err(e.into()),
        }
    } else {
        let next = format!("{stripped}\n");
        if next == existing {
            return Ok(AppendSystemRemoveOutcome::NoOp);
        }
        std::fs::write(target, &next).with_context(|| format!("writing {}", target.display()))?;
        Ok(AppendSystemRemoveOutcome::Updated)
    }
}

/// Run `append_system_upsert` for a Pi extension, reading the markdown body
/// from `<package_dir>/<pi.appendSystem>`. Returns `Ok(true)` if the file
/// changed.
///
/// When the extension does not declare `pi.appendSystem` (or the referenced
/// file is missing/empty), any previously-installed block for this extension
/// is stripped from `APPEND_SYSTEM.md`. This makes refresh self-healing when
/// an extension drops its instructions payload.
pub fn install_append_system_for(
    ext: &PiExtension,
    package_dir: &Path,
    global: bool,
) -> Result<bool> {
    let Some(rel) = ext.append_system.as_deref() else {
        return remove_append_system_if_present(&ext.name, global);
    };
    let source = package_dir.join(rel);
    let content = match std::fs::read_to_string(&source) {
        Ok(s) => s,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return remove_append_system_if_present(&ext.name, global);
        }
        Err(e) => return Err(e.into()),
    };
    if content.trim().is_empty() {
        return remove_append_system_if_present(&ext.name, global);
    }
    append_system_upsert(&append_system_path(global), &ext.name, &content)
}

fn remove_append_system_if_present(name: &str, global: bool) -> Result<bool> {
    match remove_append_system_for(name, global)? {
        AppendSystemRemoveOutcome::Updated | AppendSystemRemoveOutcome::Deleted => Ok(true),
        AppendSystemRemoveOutcome::NoOp => Ok(false),
    }
}

/// Drop the named block from the scope's APPEND_SYSTEM.md. Best-effort.
pub fn remove_append_system_for(name: &str, global: bool) -> Result<AppendSystemRemoveOutcome> {
    append_system_remove(&append_system_path(global), name)
}

fn copy_dir(src: &Path, dst: &Path) -> Result<()> {
    std::fs::create_dir_all(dst)?;
    let mut walker = walkdir::WalkDir::new(src).min_depth(1).into_iter();
    while let Some(next) = walker.next() {
        let entry = next?;
        let name = entry.file_name().to_string_lossy().to_string();
        let file_type = entry.file_type();
        if file_type.is_dir() && should_skip_copy_entry(&name) {
            walker.skip_current_dir();
            continue;
        }
        let rel = entry.path().strip_prefix(src)?;
        let target = dst.join(rel);
        if file_type.is_symlink() {
            // Recreate the link instead of letting fs::copy resolve it.
            // `vstack verify -g` byte-compares source and install; a copied
            // symlink that became a regular file in the install reads as
            // install drift on every refresh.
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            if target.is_symlink() || target.is_file() {
                std::fs::remove_file(&target).with_context(|| {
                    format!("removing existing {} for symlink replace", target.display())
                })?;
            } else if target.is_dir() {
                std::fs::remove_dir_all(&target).with_context(|| {
                    format!(
                        "removing existing dir {} for symlink replace",
                        target.display()
                    )
                })?;
            }
            let link_target = std::fs::read_link(entry.path())
                .with_context(|| format!("reading symlink target at {}", entry.path().display()))?;
            std::os::unix::fs::symlink(&link_target, &target).with_context(|| {
                format!(
                    "recreating symlink {} → {}",
                    target.display(),
                    link_target.display()
                )
            })?;
        } else if file_type.is_dir() {
            std::fs::create_dir_all(&target)?;
        } else {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent)?;
            }
            std::fs::copy(entry.path(), &target)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let mode = entry
                    .metadata()
                    .ok()
                    .map(|m| m.permissions().mode())
                    .unwrap_or(0o644);
                let _ = std::fs::set_permissions(&target, std::fs::Permissions::from_mode(mode));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_pkg(dir: &Path, json: &str) {
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("package.json"), json).unwrap();
    }

    #[test]
    fn parse_session_bridge_shape() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_pkg_session_bridge_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        write_pkg(
            &dir,
            r#"{
                "name": "pi-session-bridge",
                "version": "0.1.0",
                "description": "Pi package and CLI",
                "keywords": ["pi-package", "pi"],
                "bin": { "pi-bridge": "./bin/pi-bridge.js" },
                "pi": { "extensions": ["./extensions/session-bridge.ts"] }
            }"#,
        );
        let ext = PiExtension::from_dir(&dir).expect("parse ok");
        assert_eq!(ext.name, "pi-session-bridge");
        assert_eq!(ext.version.as_deref(), Some("0.1.0"));
        assert!(ext.keywords.contains(&"pi-package".into()));
        assert_eq!(
            ext.pi_extensions,
            vec!["./extensions/session-bridge.ts".to_string()]
        );
        assert_eq!(ext.bin.get("pi-bridge").unwrap(), "./bin/pi-bridge.js");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn parse_single_string_bin() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_pkg_single_bin_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        write_pkg(
            &dir,
            r#"{
                "name": "pi-foo",
                "bin": "./bin/foo.js"
            }"#,
        );
        let ext = PiExtension::from_dir(&dir).expect("parse ok");
        assert_eq!(ext.bin.get("pi-foo").unwrap(), "./bin/foo.js");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn discover_picks_up_packages() {
        let root = std::env::temp_dir().join(format!("vstack_pi_discover_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        write_pkg(
            &root.join("alpha"),
            r#"{ "name": "alpha", "pi": { "extensions": ["./alpha.ts"] } }"#,
        );
        write_pkg(
            &root.join("beta"),
            r#"{ "name": "beta", "pi": { "extensions": ["./beta.ts"] } }"#,
        );
        // Subdir without package.json is skipped.
        std::fs::create_dir_all(root.join("not-a-pkg")).unwrap();

        let mut discovered = discover_pi_extensions(&root).unwrap();
        discovered.sort_by(|a, b| a.name.cmp(&b.name));
        assert_eq!(discovered.len(), 2);
        assert_eq!(discovered[0].name, "alpha");
        assert_eq!(discovered[1].name, "beta");

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn relative_settings_entry_format() {
        assert_eq!(
            relative_settings_entry("pi-session-bridge"),
            "./packages/pi-session-bridge"
        );
        assert_eq!(relative_settings_entry("pi-qol"), "./packages/pi-qol");
    }

    #[test]
    fn prompt_stash_rename_has_legacy_name() {
        assert_eq!(
            legacy_names_for("@vanillagreen/pi-prompt-stash"),
            &["pi-prompt-stash", "prompt-stash"]
        );
    }

    #[test]
    fn claude_bridge_rename_has_legacy_name() {
        assert_eq!(
            legacy_names_for("@vanillagreen/pi-claude-bridge"),
            &["pi-claude-bridge"]
        );
    }

    #[test]
    fn entry_matches_package_for_relative_and_absolute_legacy() {
        let dest = Path::new("/var/tmp/scope/packages/pi-session-bridge");

        // Relative canonical form
        let rel = serde_json::Value::String("./packages/pi-session-bridge".into());
        assert!(entry_matches_package(&rel, "pi-session-bridge", dest));

        // Legacy absolute form
        let abs = serde_json::Value::String("/var/tmp/scope/packages/pi-session-bridge".into());
        assert!(entry_matches_package(&abs, "pi-session-bridge", dest));

        // Object form wrapping the absolute path
        let obj = serde_json::json!({
            "source": "/var/tmp/scope/packages/pi-session-bridge",
            "extensions": []
        });
        assert!(entry_matches_package(&obj, "pi-session-bridge", dest));

        // Unrelated entries don't match
        let other = serde_json::Value::String("npm:@foo/bar".into());
        assert!(!entry_matches_package(&other, "pi-session-bridge", dest));

        let other_pkg = serde_json::Value::String("./packages/pi-qol".into());
        assert!(!entry_matches_package(
            &other_pkg,
            "pi-session-bridge",
            dest
        ));
    }

    use crate::test_util::with_pi_dir;

    fn write_mini_source(dir: &Path, name: &str) {
        std::fs::create_dir_all(dir.join("extensions")).unwrap();
        std::fs::write(dir.join("extensions").join("mini.ts"), "// noop\n").unwrap();
        std::fs::write(
            dir.join("package.json"),
            format!(
                r#"{{ "name": "{name}", "pi": {{ "extensions": ["./extensions/mini.ts"] }} }}"#
            ),
        )
        .unwrap();
    }

    #[cfg(unix)]
    fn write_fake_npm(bin_dir: &Path, log_path: &Path) {
        use std::os::unix::fs::PermissionsExt;

        std::fs::create_dir_all(bin_dir).unwrap();
        let npm = bin_dir.join("npm");
        std::fs::write(
            &npm,
            format!(
                r#"#!/bin/sh
set -eu
log={log}
printf 'cwd=%s\n' "$PWD" > "$log"
printf 'args=' >> "$log"
for arg in "$@"; do
  printf '[%s]' "$arg" >> "$log"
done
printf '\n' >> "$log"
mkdir -p node_modules/left-pad
printf 'module.exports = 1;\n' > node_modules/left-pad/index.js
"#,
                log = shell_quote_path(log_path)
            ),
        )
        .unwrap();
        let mut perms = std::fs::metadata(&npm).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&npm, perms).unwrap();
    }

    #[cfg(unix)]
    fn write_failing_npm(bin_dir: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;

        std::fs::create_dir_all(bin_dir).unwrap();
        let npm = bin_dir.join("npm");
        std::fs::write(
            &npm,
            "#!/bin/sh\nprintf 'fixture npm failed for pi deps\\n' >&2\nexit 42\n",
        )
        .unwrap();
        let mut perms = std::fs::metadata(&npm).unwrap().permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&npm, perms).unwrap();
        npm
    }

    #[cfg(test)]
    fn with_npm_command_override<R>(command: &Path, body: impl FnOnce() -> R) -> R {
        let mut guard = match NPM_COMMAND_OVERRIDE.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        let previous = guard.replace(command.to_path_buf());
        drop(guard);

        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(body));

        let mut guard = match NPM_COMMAND_OVERRIDE.lock() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        };
        *guard = previous;

        match result {
            Ok(value) => value,
            Err(panic) => std::panic::resume_unwind(panic),
        }
    }

    fn write_runtime_dep_source(dir: &Path, name: &str) {
        std::fs::create_dir_all(dir.join("extensions")).unwrap();
        std::fs::write(dir.join("extensions").join("mini.ts"), "// noop\n").unwrap();
        std::fs::write(
            dir.join("package.json"),
            format!(
                r#"{{
                "name": "{name}",
                "pi": {{ "extensions": ["./extensions/mini.ts"] }},
                "dependencies": {{ "left-pad": "^1.3.0" }},
                "devDependencies": {{ "tsx": "^4.0.0" }},
                "peerDependencies": {{ "@earendil-works/pi-coding-agent": "*" }}
            }}"#
            ),
        )
        .unwrap();
    }

    fn assert_dependency_install_recovery_message(message: &str, package: &str, dest: &Path) {
        let expected_recovery = npm_production_install_command(dest);
        assert!(
            message.contains(&format!(
                "pi-package {package} declares production dependencies"
            )),
            "error should name package {package}, got: {message}"
        );
        assert!(
            message.contains(&format!("Recovery: `{expected_recovery}`")),
            "error should include exact recovery command, got: {message}"
        );
    }

    #[test]
    fn install_and_remove_pi_extension_round_trip() {
        let sandbox =
            std::env::temp_dir().join(format!("vstack_pi_install_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sandbox);
        std::fs::create_dir_all(&sandbox).unwrap();
        let source = sandbox.join("src").join("pi-mini");
        write_mini_source(&source, "pi-mini");
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let ext = PiExtension::from_dir(&source).unwrap();
            let dest = install_pi_extension(&ext, true).unwrap().unwrap();
            assert!(dest.join("package.json").exists());
            assert!(dest.join("extensions").join("mini.ts").exists());

            let settings_path = pi_dir.join("settings.json");
            let settings: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            let pkgs = settings
                .get("packages")
                .and_then(|p| p.as_array())
                .expect("packages array");
            // We write the canonical relative form, not the absolute path
            let want = relative_settings_entry("pi-mini");
            assert!(
                pkgs.iter()
                    .any(|e| matches!(e, serde_json::Value::String(s) if s == &want)),
                "expected {want} in {pkgs:?}"
            );
            // And NEVER leak the absolute path
            let absolute = dest.to_string_lossy().into_owned();
            assert!(
                !pkgs
                    .iter()
                    .any(|e| matches!(e, serde_json::Value::String(s) if s == &absolute)),
                "absolute path leaked into settings: {pkgs:?}"
            );

            // Remove
            let _ = remove_pi_extension(&ext.name, true).unwrap();
            assert!(!dest.exists());

            let after: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            assert!(
                after.get("packages").is_none(),
                "expected packages key gone after sole package removed, got {after}"
            );
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn runtime_dependency_detection_ignores_dev_and_peer_dependencies() {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_runtime_dep_detect_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        write_pkg(
            &dir,
            r#"{
                "name": "pi-dev-only",
                "devDependencies": { "tsx": "^4.0.0" },
                "peerDependencies": { "@earendil-works/pi-coding-agent": "*" }
            }"#,
        );
        assert!(!package_declares_runtime_dependencies(&dir).unwrap());

        std::fs::write(
            dir.join("package.json"),
            r#"{
                "name": "pi-runtime",
                "optionalDependencies": { "left-pad": "^1.3.0" }
            }"#,
        )
        .unwrap();
        assert!(package_declares_runtime_dependencies(&dir).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn install_pi_extension_installs_declared_production_dependencies() {
        let sandbox = std::env::temp_dir().join(format!(
            "vstack_pi_install_runtime_deps_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&sandbox);
        let source = sandbox.join("src").join("pi-needs-deps");
        write_runtime_dep_source(&source, "pi-needs-deps");

        let fake_bin = sandbox.join("fake-bin");
        let npm_log = sandbox.join("npm.log");
        write_fake_npm(&fake_bin, &npm_log);
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let ext = PiExtension::from_dir(&source).unwrap();
            let dest = with_npm_command_override(&fake_bin.join("npm"), || {
                install_pi_extension(&ext, true).unwrap().unwrap()
            });

            assert!(
                dest.join("node_modules")
                    .join("left-pad")
                    .join("index.js")
                    .exists()
            );
            let log = std::fs::read_to_string(&npm_log).unwrap();
            assert!(
                log.contains(&format!("cwd={}", dest.display())),
                "npm should run inside deployed package dir, got log: {log}"
            );
            assert!(
                log.contains("args=[install][--omit=dev][--package-lock=false][--legacy-peer-deps][--no-audit][--no-fund]"),
                "npm should install production deps only, got log: {log}"
            );
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[cfg(unix)]
    #[test]
    fn install_pi_extension_reports_missing_npm_with_recovery_command() {
        let sandbox = std::env::temp_dir().join(format!(
            "vstack_pi_missing_npm_runtime_deps_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&sandbox);
        let source = sandbox.join("src").join("pi-missing-npm");
        write_runtime_dep_source(&source, "pi-missing-npm");
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let ext = PiExtension::from_dir(&source).unwrap();
            let missing_npm = sandbox.join("bin").join("npm-does-not-exist");
            let err = with_npm_command_override(&missing_npm, || {
                install_pi_extension(&ext, true).unwrap_err()
            });
            let message = format!("{err:#}");
            let dest = pi_dir.join("packages").join("pi-missing-npm");

            assert!(
                message.contains("npm could not run"),
                "missing npm error should explain npm could not run, got: {message}"
            );
            assert_dependency_install_recovery_message(&message, "pi-missing-npm", &dest);
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[cfg(unix)]
    #[test]
    fn install_pi_extension_reports_npm_nonzero_with_recovery_command() {
        let sandbox = std::env::temp_dir().join(format!(
            "vstack_pi_failing_npm_runtime_deps_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&sandbox);
        let source = sandbox.join("src").join("pi-failing-npm");
        write_runtime_dep_source(&source, "pi-failing-npm");
        let fake_npm = write_failing_npm(&sandbox.join("fake-bin"));
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let ext = PiExtension::from_dir(&source).unwrap();
            let err = with_npm_command_override(&fake_npm, || {
                install_pi_extension(&ext, true).unwrap_err()
            });
            let message = format!("{err:#}");
            let dest = pi_dir.join("packages").join("pi-failing-npm");

            assert!(
                message.contains("`npm install` failed"),
                "non-zero npm error should explain npm install failed, got: {message}"
            );
            assert!(
                message.contains("fixture npm failed for pi deps"),
                "non-zero npm error should include stderr details, got: {message}"
            );
            assert_dependency_install_recovery_message(&message, "pi-failing-npm", &dest);
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn install_creates_and_remove_clears_bin_symlinks() {
        let sandbox =
            std::env::temp_dir().join(format!("vstack_pi_bin_links_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sandbox);
        let source = sandbox.join("src").join("pi-bridgey");
        std::fs::create_dir_all(source.join("bin")).unwrap();
        std::fs::create_dir_all(source.join("extensions")).unwrap();
        std::fs::write(source.join("extensions").join("ext.ts"), "// noop\n").unwrap();
        std::fs::write(
            source.join("bin").join("pi-bridge.js"),
            "#!/usr/bin/env node\n",
        )
        .unwrap();
        std::fs::write(
            source.join("package.json"),
            r#"{
                "name": "pi-bridgey",
                "pi": { "extensions": ["./extensions/ext.ts"] },
                "bin": { "pi-bridge": "./bin/pi-bridge.js" }
            }"#,
        )
        .unwrap();
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let ext = PiExtension::from_dir(&source).unwrap();
            let dest = install_pi_extension(&ext, true).unwrap().unwrap();

            let link = pi_dir.join("bin").join("pi-bridge");
            assert!(
                link.is_symlink(),
                "expected bin symlink at {}",
                link.display()
            );
            let target = std::fs::read_link(&link).unwrap();
            assert_eq!(target, dest.join("./bin/pi-bridge.js"));

            // Remove clears the symlink
            let removed = remove_pi_extension(&ext.name, true).unwrap();
            assert!(
                removed.iter().any(|p| p == &link),
                "expected remove output to include bin link {}",
                link.display()
            );
            assert!(!link.exists(), "bin link should be gone");
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn install_pi_agents_tmux_migrates_legacy_subagent_packages() {
        let sandbox =
            std::env::temp_dir().join(format!("vstack_pi_agents_migrate_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sandbox);
        std::fs::create_dir_all(&sandbox).unwrap();
        let oldest_src = sandbox.join("src").join("pi-subagents");
        let mid_src = sandbox.join("src").join("pi-subagents-tmux");
        let prev_src = sandbox.join("src").join("pi-agents-tmux");
        let current_src = sandbox.join("src").join("vg-pi-agents-tmux");
        write_mini_source(&oldest_src, "pi-subagents");
        write_mini_source(&mid_src, "pi-subagents-tmux");
        write_mini_source(&prev_src, "pi-agents-tmux");
        write_mini_source(&current_src, "@vanillagreen/pi-agents-tmux");
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let oldest = PiExtension::from_dir(&oldest_src).unwrap();
            let oldest_dest = install_pi_extension(&oldest, true).unwrap().unwrap();
            assert!(oldest_dest.exists());
            let mid = PiExtension::from_dir(&mid_src).unwrap();
            let mid_dest = install_pi_extension(&mid, true).unwrap().unwrap();
            assert!(mid_dest.exists());
            let prev = PiExtension::from_dir(&prev_src).unwrap();
            let prev_dest = install_pi_extension(&prev, true).unwrap().unwrap();
            assert!(prev_dest.exists());

            let current = PiExtension::from_dir(&current_src).unwrap();
            let current_dest = install_pi_extension(&current, true).unwrap().unwrap();
            assert!(current_dest.exists());
            assert!(
                !oldest_dest.exists(),
                "oldest legacy package dir should be removed during rename migration"
            );
            assert!(
                !mid_dest.exists(),
                "mid legacy package dir should be removed during rename migration"
            );
            assert!(
                !prev_dest.exists(),
                "previous unscoped legacy package dir should be removed during rename migration"
            );

            let settings_path = pi_dir.join("settings.json");
            let settings: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            let pkgs: Vec<&str> = settings
                .get("packages")
                .and_then(|p| p.as_array())
                .unwrap()
                .iter()
                .filter_map(|e| e.as_str())
                .collect();
            assert!(pkgs.contains(&"./packages/@vanillagreen/pi-agents-tmux"));
            assert!(
                !pkgs.contains(&"./packages/pi-agents-tmux"),
                "previous unscoped settings entry should be removed, got {pkgs:?}"
            );
            assert!(
                !pkgs.contains(&"./packages/pi-subagents-tmux"),
                "mid legacy settings entry should be removed, got {pkgs:?}"
            );
            assert!(
                !pkgs.contains(&"./packages/pi-subagents"),
                "oldest legacy settings entry should be removed, got {pkgs:?}"
            );
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn remove_pi_extension_cleans_stale_settings_entry() {
        let sandbox = std::env::temp_dir().join(format!(
            "vstack_pi_remove_stale_settings_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&sandbox);
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let settings_path = pi_dir.join("settings.json");
            std::fs::create_dir_all(&pi_dir).unwrap();
            std::fs::write(
                &settings_path,
                serde_json::to_string_pretty(&serde_json::json!({
                    "packages": ["./packages/pi-stale"],
                }))
                .unwrap(),
            )
            .unwrap();

            assert!(is_pi_extension_installed("pi-stale", true));
            let removed = remove_pi_extension("pi-stale", true).unwrap();
            assert!(
                removed.iter().any(|p| p == &settings_path),
                "settings.json should be reported as changed"
            );

            let after: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            assert!(after.get("packages").is_none());
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn install_two_pi_extensions_coexist_and_preserve_other_settings() {
        let sandbox =
            std::env::temp_dir().join(format!("vstack_pi_two_install_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sandbox);
        std::fs::create_dir_all(&sandbox).unwrap();
        let bridge_src = sandbox.join("src").join("pi-session-bridge");
        let qol_src = sandbox.join("src").join("pi-qol");
        write_mini_source(&bridge_src, "pi-session-bridge");
        write_mini_source(&qol_src, "pi-qol");

        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            // Pre-seed settings with unrelated content + a third-party package
            let settings_path = pi_dir.join("settings.json");
            std::fs::create_dir_all(&pi_dir).unwrap();
            std::fs::write(
                &settings_path,
                serde_json::to_string_pretty(&serde_json::json!({
                    "theme": "dark",
                    "packages": ["npm:@foo/bar"],
                }))
                .unwrap(),
            )
            .unwrap();

            // Install both vstack-managed packages
            let bridge = PiExtension::from_dir(&bridge_src).unwrap();
            let qol = PiExtension::from_dir(&qol_src).unwrap();
            install_pi_extension(&bridge, true).unwrap().unwrap();
            install_pi_extension(&qol, true).unwrap().unwrap();

            // Re-install one to verify dedupe (no duplicate entries)
            install_pi_extension(&qol, true).unwrap().unwrap();

            let settings: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            let pkgs: Vec<&str> = settings
                .get("packages")
                .and_then(|p| p.as_array())
                .unwrap()
                .iter()
                .filter_map(|e| e.as_str())
                .collect();
            assert!(pkgs.contains(&"npm:@foo/bar"), "third-party preserved");
            assert!(pkgs.contains(&"./packages/pi-session-bridge"));
            assert!(pkgs.contains(&"./packages/pi-qol"));
            // Dedupe: pi-qol appears exactly once
            assert_eq!(
                pkgs.iter().filter(|s| **s == "./packages/pi-qol").count(),
                1,
                "expected pi-qol once, got {pkgs:?}"
            );
            assert_eq!(settings.get("theme").and_then(|t| t.as_str()), Some("dark"));
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn reinstall_preserves_extension_manager_user_config() {
        let sandbox = std::env::temp_dir().join(format!(
            "vstack_pi_preserve_ext_config_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&sandbox);
        std::fs::create_dir_all(&sandbox).unwrap();
        let source = sandbox.join("src").join("pi-qol");
        write_mini_source(&source, "pi-qol");
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            let settings_path = pi_dir.join("settings.json");
            std::fs::create_dir_all(&pi_dir).unwrap();
            let user_config = serde_json::json!({
                "newlineOnShiftEnter": false,
                "newlineFallbackKey": "none",
                "permissionGate.enabled": false,
                "customUserSetting": "must-survive-refresh"
            });
            std::fs::write(
                &settings_path,
                serde_json::to_string_pretty(&serde_json::json!({
                    "theme": "dark",
                    "packages": ["npm:@foo/bar", "./packages/pi-qol", "./packages/pi-tool-renderer"],
                    "vstack": {
                        "extensionManager": {
                            "config": {
                                "pi-qol": user_config,
                                "pi-tool-renderer": { "enabled": false }
                            },
                            "disabledItems": ["tool:example"],
                            "disabledProviders": ["provider:example"]
                        }
                    }
                }))
                .unwrap(),
            )
            .unwrap();

            let ext = PiExtension::from_dir(&source).unwrap();
            install_pi_extension(&ext, true).unwrap().unwrap();
            // vstack refresh/update re-enters the same install path; verify a
            // second install only re-copies package files and de-dupes packages,
            // never rewriting extension-manager user config.
            install_pi_extension(&ext, true).unwrap().unwrap();

            let settings: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            let manager = settings
                .get("vstack")
                .and_then(|v| v.get("extensionManager"))
                .expect("extension manager config should survive reinstall");
            assert_eq!(
                manager.get("config").and_then(|c| c.get("pi-qol")),
                Some(&user_config),
                "pi-qol user settings must not be clobbered by reinstall/refresh"
            );
            assert_eq!(
                manager
                    .get("config")
                    .and_then(|c| c.get("pi-tool-renderer"))
                    .and_then(|c| c.get("enabled"))
                    .and_then(|v| v.as_bool()),
                Some(false),
                "other extension settings must also be preserved"
            );
            assert_eq!(
                manager
                    .get("disabledItems")
                    .and_then(|v| v.as_array())
                    .map(|a| a.len()),
                Some(1)
            );
            assert_eq!(settings.get("theme").and_then(|t| t.as_str()), Some("dark"));

            let pkgs: Vec<&str> = settings
                .get("packages")
                .and_then(|p| p.as_array())
                .unwrap()
                .iter()
                .filter_map(|e| e.as_str())
                .collect();
            assert!(pkgs.contains(&"npm:@foo/bar"));
            assert_eq!(
                pkgs.iter().filter(|s| **s == "./packages/pi-qol").count(),
                1,
                "reinstall should not duplicate package entries: {pkgs:?}"
            );
            assert_eq!(
                pkgs,
                vec![
                    "npm:@foo/bar",
                    "./packages/pi-qol",
                    "./packages/pi-tool-renderer"
                ],
                "reinstall should preserve package load order: {pkgs:?}"
            );
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn install_dedupes_legacy_absolute_path_entry() {
        let sandbox =
            std::env::temp_dir().join(format!("vstack_pi_legacy_dedupe_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sandbox);
        std::fs::create_dir_all(&sandbox).unwrap();
        let source = sandbox.join("src").join("pi-mini");
        write_mini_source(&source, "pi-mini");
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            // Pre-seed settings with a legacy absolute-path entry
            let dest = pi_dir.join("packages").join("pi-mini");
            let settings_path = pi_dir.join("settings.json");
            std::fs::create_dir_all(&pi_dir).unwrap();
            std::fs::write(
                &settings_path,
                serde_json::to_string_pretty(&serde_json::json!({
                    "packages": [dest.to_string_lossy()],
                }))
                .unwrap(),
            )
            .unwrap();

            let ext = PiExtension::from_dir(&source).unwrap();
            install_pi_extension(&ext, true).unwrap().unwrap();

            let settings: serde_json::Value =
                serde_json::from_str(&std::fs::read_to_string(&settings_path).unwrap()).unwrap();
            let pkgs: Vec<&str> = settings
                .get("packages")
                .and_then(|p| p.as_array())
                .unwrap()
                .iter()
                .filter_map(|e| e.as_str())
                .collect();
            // Legacy absolute path replaced by relative form, no duplicates
            assert_eq!(pkgs, vec!["./packages/pi-mini"]);
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[test]
    fn parse_pi_qol_package() {
        let dir = std::env::temp_dir().join(format!("vstack_pi_qol_parse_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        write_pkg(
            &dir,
            r#"{
                "name": "pi-qol",
                "version": "0.1.0",
                "description": "Pi quality-of-life helpers.",
                "keywords": ["pi-package", "pi", "qol"],
                "pi": { "extensions": ["./extensions/qol.ts"] },
                "peerDependencies": {
                    "@mariozechner/pi-coding-agent": "*",
                    "@mariozechner/pi-tui": "*"
                }
            }"#,
        );
        let ext = PiExtension::from_dir(&dir).unwrap();
        assert_eq!(ext.name, "pi-qol");
        assert!(ext.bin.is_empty(), "qol has no CLI bin");
        assert_eq!(ext.pi_extensions, vec!["./extensions/qol.ts".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn append_system_upsert_and_remove_roundtrip() {
        let dir = std::env::temp_dir().join(format!("vstack_append_sys_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let target = dir.join("APPEND_SYSTEM.md");

        // First insert: file is created with one block.
        let changed = append_system_upsert(&target, "@scope/pkg", "## pkg\nrule.\n").unwrap();
        assert!(changed);
        let body = std::fs::read_to_string(&target).unwrap();
        assert!(body.contains("<!-- vstack:append-system @scope/pkg begin -->"));
        assert!(body.contains("## pkg"));
        assert!(body.trim_end().ends_with("end -->"));

        // Idempotent re-upsert: same content, no change.
        let changed = append_system_upsert(&target, "@scope/pkg", "## pkg\nrule.\n").unwrap();
        assert!(!changed);

        // Updated content replaces the previous block, no duplicate markers.
        let changed = append_system_upsert(&target, "@scope/pkg", "## pkg v2\n").unwrap();
        assert!(changed);
        let body = std::fs::read_to_string(&target).unwrap();
        assert_eq!(body.matches("begin -->").count(), 1);
        assert!(body.contains("## pkg v2"));
        assert!(!body.contains("## pkg\nrule."));

        // Pre-existing user content above is preserved across upserts.
        std::fs::write(&target, format!("# user rules\nkeep me.\n\n{body}")).unwrap();
        let changed = append_system_upsert(&target, "@scope/pkg", "## pkg v3\n").unwrap();
        assert!(changed);
        let body = std::fs::read_to_string(&target).unwrap();
        assert!(body.starts_with("# user rules\nkeep me."));
        assert!(body.contains("## pkg v3"));
        assert_eq!(body.matches("begin -->").count(), 1);

        // Second package adds a separate block.
        let changed = append_system_upsert(&target, "@scope/other", "## other\n").unwrap();
        assert!(changed);
        let body = std::fs::read_to_string(&target).unwrap();
        assert!(body.contains("@scope/pkg begin"));
        assert!(body.contains("@scope/other begin"));

        // Removing one block leaves the other and the user content intact.
        let outcome = append_system_remove(&target, "@scope/pkg").unwrap();
        assert_eq!(outcome, AppendSystemRemoveOutcome::Updated);
        let body = std::fs::read_to_string(&target).unwrap();
        assert!(!body.contains("@scope/pkg"));
        assert!(body.contains("@scope/other begin"));
        assert!(body.starts_with("# user rules"));

        // Remove again: no-op.
        let outcome = append_system_remove(&target, "@scope/pkg").unwrap();
        assert_eq!(outcome, AppendSystemRemoveOutcome::NoOp);

        // Removing the last block when no user content remains deletes the file.
        std::fs::write(
            &target,
            "<!-- vstack:append-system @scope/only begin -->\nrule.\n<!-- vstack:append-system @scope/only end -->\n",
        )
        .unwrap();
        let outcome = append_system_remove(&target, "@scope/only").unwrap();
        assert_eq!(outcome, AppendSystemRemoveOutcome::Deleted);
        assert!(!target.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pi_extension_parses_append_system() {
        let dir =
            std::env::temp_dir().join(format!("vstack_pi_appsys_parse_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        write_pkg(
            &dir,
            r#"{
                "name": "@scope/test",
                "version": "0.1.0",
                "pi": { "extensions": ["./extensions/x.ts"], "appendSystem": "./instructions.md" }
            }"#,
        );
        let ext = PiExtension::from_dir(&dir).unwrap();
        assert_eq!(ext.append_system.as_deref(), Some("./instructions.md"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// End-to-end smoke test that installs all vstack-managed Pi packages
    /// from the repo into a sandboxed `PI_CODING_AGENT_DIR`, then launches
    /// `pi` in non-interactive mode and confirms it prints no extension errors.
    ///
    /// Skipped by default (and silently skipped when `pi` is not on PATH so
    /// the suite still passes for users without Pi installed). Run with:
    ///
    /// ```bash
    /// cargo test --test-threads=1 pi_smoke_install_and_launch -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "exercises real `pi` binary; opt-in via --ignored"]
    fn pi_smoke_install_and_launch() {
        // Locate and install every repo-managed Pi package relative
        // to CARGO_MANIFEST_DIR, so this smoke stays current as the catalog grows.
        let manifest_dir = Path::new(env!("CARGO_MANIFEST_DIR"));
        let pi_ext_root = manifest_dir
            .parent()
            .expect("repo root above cli/")
            .join("pi-extensions");
        let extensions = discover_pi_extensions(&pi_ext_root).unwrap();
        if extensions.is_empty() {
            eprintln!("skipping pi_smoke: no pi-packages found");
            return;
        }

        // If `pi` isn't installed, skip silently — this test exists for
        // operators who actually have Pi available.
        let pi_on_path = std::env::var_os("PATH")
            .map(|paths| std::env::split_paths(&paths).any(|p| p.join("pi").is_file()))
            .unwrap_or(false);
        if !pi_on_path {
            eprintln!("skipping pi_smoke: `pi` not on PATH");
            return;
        }

        let sandbox = std::env::temp_dir().join(format!("vstack_pi_smoke_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&sandbox);
        std::fs::create_dir_all(&sandbox).unwrap();
        let pi_dir = sandbox.join("agent");

        with_pi_dir(&pi_dir, || {
            for ext in &extensions {
                install_pi_extension(ext, true).unwrap().unwrap();
            }

            let bridge_dir = sandbox.join("bridge");
            let output = std::process::Command::new("pi")
                .args([
                    "--mode",
                    "json",
                    "--no-session",
                    "--no-tools",
                    "--thinking",
                    "off",
                    "-p",
                    "ping",
                ])
                .env("PI_CODING_AGENT_DIR", &pi_dir)
                .env("PI_BRIDGE_DIR", &bridge_dir)
                .env("PI_TELEMETRY", "0")
                .output()
                .expect("spawn pi");

            let stderr = String::from_utf8_lossy(&output.stderr);
            let stdout = String::from_utf8_lossy(&output.stdout);
            let combined = format!("{stderr}\n{stdout}");

            // Pi must not emit extension load errors for our packages
            assert!(
                !combined.contains("extension_error"),
                "pi reported extension_error: {combined}"
            );
            {
                let forbidden = "Failed to load extension";
                assert!(
                    !combined.contains(forbidden),
                    "pi reported `{forbidden}`: {combined}"
                );
            }
        });

        let _ = std::fs::remove_dir_all(&sandbox);
    }

    #[cfg(unix)]
    #[test]
    fn pi_copy_dir_preserves_symlinks() {
        // Pi packages have their own copy_dir (separate from installer.rs).
        // Both must preserve symlinks; without this, integration tests that
        // create symlink artifacts (e.g. pi-claude-bridge's `.test-output/`)
        // make every refresh report install drift.
        use std::os::unix::fs::symlink;

        let root =
            std::env::temp_dir().join(format!("vstack_pi_copy_dir_symlink_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let src = root.join("src");
        let dst = root.join("dst");
        std::fs::create_dir_all(src.join("logs")).unwrap();
        let real = src.join("logs").join("a.log");
        std::fs::write(&real, b"hello\n").unwrap();
        symlink(&real, src.join("logs").join("latest")).unwrap();

        copy_dir(&src, &dst).unwrap();

        let dst_link = dst.join("logs").join("latest");
        let meta = std::fs::symlink_metadata(&dst_link).unwrap();
        assert!(
            meta.file_type().is_symlink(),
            "pi copy_dir must preserve symlinks; got file_type={:?}",
            meta.file_type()
        );
        assert_eq!(std::fs::read_link(&dst_link).unwrap(), real);
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn pi_copy_dir_skips_test_output_dir() {
        // `.test-output/` is gitignored test scratch; it must not ship into
        // the install dir even if the package author forgets to delete it.
        let root = std::env::temp_dir().join(format!(
            "vstack_pi_copy_dir_skip_test_output_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&root);
        let src = root.join("src");
        let dst = root.join("dst");
        std::fs::create_dir_all(src.join(".test-output").join("nested")).unwrap();
        std::fs::write(
            src.join(".test-output").join("nested").join("out.log"),
            b"junk",
        )
        .unwrap();
        std::fs::write(src.join("package.json"), b"{}").unwrap();

        copy_dir(&src, &dst).unwrap();

        assert!(dst.join("package.json").exists());
        assert!(
            !dst.join(".test-output").exists(),
            ".test-output must be skipped during install"
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn list_installed_vstack_packages_reports_scoped_packages() {
        let sandbox = std::env::temp_dir().join(format!(
            "vstack_list_installed_scoped_{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&sandbox);
        let pi_dir = sandbox.join("agent");
        let pkgs_dir = pi_dir.join("packages");
        // Scoped package: <scope>/packages/@scope/name/package.json
        let scoped = pkgs_dir.join("@vanillagreen").join("pi-foo");
        std::fs::create_dir_all(&scoped).unwrap();
        std::fs::write(
            scoped.join("package.json"),
            r#"{"name":"@vanillagreen/pi-foo"}"#,
        )
        .unwrap();
        // Unscoped package alongside it: <scope>/packages/legacy/package.json
        let legacy = pkgs_dir.join("legacy-pkg");
        std::fs::create_dir_all(&legacy).unwrap();
        std::fs::write(legacy.join("package.json"), r#"{"name":"legacy-pkg"}"#).unwrap();

        let names = with_pi_dir(&pi_dir, || list_installed_vstack_packages(true));
        assert!(
            names.iter().any(|n| n == "@vanillagreen/pi-foo"),
            "scoped package must be reported with full @scope/name; got {names:?}"
        );
        assert!(
            names.iter().any(|n| n == "legacy-pkg"),
            "unscoped package alongside scope dir must still appear; got {names:?}"
        );
        let _ = std::fs::remove_dir_all(&sandbox);
    }
}
