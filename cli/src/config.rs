use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Lock file entry for tracking installed items
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LockEntry {
    pub name: String,
    pub kind: ItemKind,
    pub source: String,
    /// GitHub `owner/repo` identity for the source checkout/remote recorded at
    /// install time. This is durable across moved or absent local paths and is
    /// used for ownership routing where installed assets have no frontmatter.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source_repo: Option<String>,
    pub harnesses: Vec<String>,
    pub method: InstallMethod,
    pub installed_at: String,
    /// Content hash of the source at install time. Used for staleness
    /// detection instead of mtime (immune to git checkout/rebase).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub source_hash: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ItemKind {
    Skill,
    Agent,
    Hook,
    PiExtension,
    Extra,
}

impl ItemKind {
    /// Short human label used in TUI rows, dialogs, and inspector. Stays
    /// consistent with [`Display`] except `PiExtension` reads as
    /// "pi-package" — that's what users call them in the package manager.
    pub fn label_short(self) -> &'static str {
        match self {
            ItemKind::Agent => "agent",
            ItemKind::Skill => "skill",
            ItemKind::Hook => "hook",
            ItemKind::PiExtension => "pi-package",
            ItemKind::Extra => "extra",
        }
    }

    /// Same as [`label_short`] but accepts `Option<ItemKind>`; falls back
    /// to "item" when None (e.g. the `vstack (cli)` binary update entry).
    pub fn label_short_or_item(kind: Option<Self>) -> &'static str {
        kind.map_or("item", Self::label_short)
    }
}

impl std::fmt::Display for ItemKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ItemKind::Skill => write!(f, "skill"),
            ItemKind::Agent => write!(f, "agent"),
            ItemKind::Hook => write!(f, "hook"),
            ItemKind::PiExtension => write!(f, "pi-extension"),
            ItemKind::Extra => write!(f, "extra"),
        }
    }
}

#[cfg(test)]
mod item_kind_tests {
    use super::ItemKind;

    #[test]
    fn extra_round_trips_through_serialization_and_display() {
        let encoded = serde_json::to_string(&ItemKind::Extra).unwrap();
        assert_eq!(encoded, "\"extra\"");

        let decoded: ItemKind = serde_json::from_str(&encoded).unwrap();
        assert_eq!(decoded, ItemKind::Extra);
        assert_eq!(ItemKind::Extra.to_string(), "extra");
        assert_eq!(ItemKind::Extra.label_short(), "extra");
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InstallMethod {
    Symlink,
    Copy,
}

impl std::fmt::Display for InstallMethod {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            InstallMethod::Symlink => write!(f, "symlink"),
            InstallMethod::Copy => write!(f, "copy"),
        }
    }
}

/// Lock file tracking all installations
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct LockFile {
    pub version: u32,
    pub entries: BTreeMap<String, LockEntry>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SourceRegistry {
    /// Last selected source outside a project-scoped install.
    pub current: Option<String>,
    pub entries: Vec<String>,
    /// Sources the user explicitly removed. This lets vstack ship a default
    /// source for fresh installs without resurrecting it after removal.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed_entries: Vec<String>,
    /// Last selected source per project root. This prevents choosing a source
    /// in one project from silently changing the package source used by
    /// another project.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub project_current: BTreeMap<String, String>,
}

impl LockFile {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self {
                version: 1,
                ..Default::default()
            });
        }
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("reading lock file {}", path.display()))?;
        serde_json::from_str(&content).context("parsing lock file")
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = serde_json::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    pub fn add(&mut self, entry: LockEntry) {
        self.entries.insert(entry.name.clone(), entry);
    }

    pub fn remove(&mut self, name: &str) -> Option<LockEntry> {
        self.entries.remove(name)
    }
}

impl SourceRegistry {
    pub fn load(path: &Path) -> Result<Self> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let content = std::fs::read_to_string(path)
            .with_context(|| format!("reading source registry {}", path.display()))?;
        let mut registry: Self =
            serde_json::from_str(&content).context("parsing source registry")?;
        let pruned = registry.prune_dead_paths();
        if pruned > 0 {
            // Best-effort persist; if it fails we still return the in-memory
            // pruned view so the rest of the run sees a clean list.
            let _ = registry.save(path);
        }
        Ok(registry)
    }

    /// Drop entries that look like local filesystem paths but no longer exist.
    /// Remote shorthand entries (e.g. "owner/repo", "https://...") are
    /// preserved unconditionally — they're not paths to check. Returns the
    /// number of entries removed.
    pub fn prune_dead_paths(&mut self) -> usize {
        let before = self.entries.len();
        self.entries.retain(|entry| !is_dead_local_path(entry));
        if let Some(current) = &self.current
            && is_dead_local_path(current)
        {
            self.current = None;
        }
        let before_project = self.project_current.len();
        self.project_current
            .retain(|_, source| !is_dead_local_path(source));
        before - self.entries.len() + before_project - self.project_current.len()
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = serde_json::to_string_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    pub fn remember(&mut self, source: &str) {
        // Temporary installer sandboxes should be usable for the current
        // command, but should not become sticky source choices in the user's
        // global registry. They are often one-off partial vstack sources such
        // as /tmp/vstack-install-<package>.
        if is_temporary_local_path(source) {
            return;
        }
        self.remember_entry(source);
        self.current = Some(source.to_string());
    }

    pub fn remember_for_project(&mut self, project_root: &Path, source: &str) {
        // Same temp-source rule as the global current: allow the current
        // command to use /tmp explicitly, but don't make it sticky.
        if is_temporary_local_path(source) {
            return;
        }
        self.remember_entry(source);
        self.project_current
            .insert(project_key(project_root), source.to_string());
    }

    pub fn current_for_project(&self, project_root: &Path) -> Option<&str> {
        self.project_current
            .get(&project_key(project_root))
            .map(String::as_str)
    }

    fn remember_entry(&mut self, source: &str) {
        if !self.entries.iter().any(|entry| entry == source) {
            self.entries.push(source.to_string());
        }
    }

    pub fn forget(&mut self, source: &str) {
        self.entries.retain(|e| e != source);
        if self.current.as_deref() == Some(source) {
            self.current = None;
        }
        self.project_current.retain(|_, current| current != source);
        if !self.removed_entries.iter().any(|entry| entry == source) {
            self.removed_entries.push(source.to_string());
        }
    }

    pub fn was_removed(&self, source: &str) -> bool {
        self.removed_entries.iter().any(|entry| entry == source)
    }
}

fn project_key(project_root: &Path) -> String {
    project_root
        .canonicalize()
        .unwrap_or_else(|_| project_root.to_path_buf())
        .display()
        .to_string()
}

/// True iff `entry` looks like a local filesystem path (absolute, `~`-tilde,
/// or relative starting with `.`) that no longer exists. Anything that doesn't
/// match those shapes (remote shorthand `owner/repo`, URLs, etc.) is left
/// alone — only path-like entries can become dead.
fn is_dead_local_path(entry: &str) -> bool {
    expanded_local_path(entry).is_some_and(|expanded| !expanded.exists())
}

/// True iff `entry` is a local path under the OS temp directory. These paths
/// are valid to install from explicitly, but should not be remembered as
/// durable package sources.
///
/// Matches both raw and canonicalized forms because a non-existent path
/// can't be canonicalized (`canonicalize` requires an existing path), and
/// macOS reports `/tmp` raw while canonicalize maps it to `/private/tmp`.
/// Without checking both forms, a path like `/tmp/vstack-install-foo` that
/// has already been cleaned up by the installer is treated as non-temporary
/// and gets remembered as a sticky source.
fn is_temporary_local_path(entry: &str) -> bool {
    let Some(path) = expanded_local_path(entry) else {
        return false;
    };
    let raw_temp = std::env::temp_dir();
    let canonical_temp = raw_temp.canonicalize().unwrap_or_else(|_| raw_temp.clone());
    let raw_path = path.clone();
    let canonical_path = path.canonicalize().unwrap_or_else(|_| path.clone());

    let mut prefixes: Vec<PathBuf> = vec![raw_temp.clone(), canonical_temp.clone()];
    // macOS: /tmp is a symlink to /private/tmp. canonicalize() follows it,
    // but a non-existent /tmp/foo can't be canonicalized, so we also accept
    // the raw /tmp form whenever the canonical form is /private/tmp (or
    // vice versa).
    if canonical_temp == Path::new("/private/tmp") {
        prefixes.push(PathBuf::from("/tmp"));
    }
    if raw_temp == Path::new("/tmp") {
        prefixes.push(PathBuf::from("/private/tmp"));
    }

    prefixes
        .iter()
        .any(|p| raw_path.starts_with(p) || canonical_path.starts_with(p))
}

fn expanded_local_path(entry: &str) -> Option<PathBuf> {
    let looks_like_path = entry.starts_with('/')
        || entry.starts_with('~')
        || entry.starts_with("./")
        || entry.starts_with("../");
    if !looks_like_path {
        return None;
    }
    Some(if let Some(stripped) = entry.strip_prefix("~/") {
        user_home_dir().join(stripped)
    } else if entry == "~" {
        user_home_dir()
    } else {
        PathBuf::from(entry)
    })
}

/// Resolve the lock file path based on scope
pub fn lock_file_path(global: bool) -> PathBuf {
    if global {
        global_state_dir().join(".vstack-lock.json")
    } else {
        project_root().join(".vstack-lock.json")
    }
}

pub fn user_home_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = crate::test_util::home_dir_override() {
        return path;
    }
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("~"))
}

pub fn user_config_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = crate::test_util::config_dir_override() {
        return path;
    }
    dirs::config_dir().unwrap_or_else(|| user_home_dir().join(".config"))
}

pub fn global_state_dir() -> PathBuf {
    user_config_dir().join("vstack")
}

pub fn source_registry_path() -> PathBuf {
    global_state_dir().join("sources.json")
}

pub fn display_path(path: &Path) -> String {
    let home = user_home_dir();
    if let Ok(rel) = path.strip_prefix(&home) {
        if rel.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", rel.display())
        }
    } else {
        path.display().to_string()
    }
}

/// Base directory for legacy home-scoped global installations.
pub fn global_base_dir() -> PathBuf {
    user_home_dir()
}

pub fn claude_global_dir() -> PathBuf {
    user_home_dir().join(".claude")
}

pub fn cursor_global_dir() -> PathBuf {
    user_home_dir().join(".cursor")
}

pub fn opencode_global_dir() -> PathBuf {
    if let Some(config_path) = std::env::var_os("OPENCODE_CONFIG").map(PathBuf::from)
        && let Some(parent) = config_path.parent()
    {
        return parent.to_path_buf();
    }
    std::env::var_os("OPENCODE_CONFIG_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| user_config_dir().join("opencode"))
}

pub fn opencode_global_config_path() -> PathBuf {
    std::env::var_os("OPENCODE_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|| opencode_global_dir().join("opencode.json"))
}

pub fn opencode_project_config_path() -> PathBuf {
    let root = project_root();
    let json = root.join("opencode.json");
    if json.exists() {
        return json;
    }
    let jsonc = root.join("opencode.jsonc");
    if jsonc.exists() {
        return jsonc;
    }
    json
}

pub fn codex_home_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = crate::test_util::codex_home_override() {
        return path;
    }

    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| user_home_dir().join(".codex"))
}

/// Global Pi config directory.
///
/// Honors `PI_CODING_AGENT_DIR` so tests can redirect to a sandbox dir
/// without touching the real `~/.pi/agent`.
pub fn pi_global_dir() -> PathBuf {
    #[cfg(test)]
    if let Some(path) = crate::test_util::pi_dir_override() {
        return path;
    }

    std::env::var_os("PI_CODING_AGENT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| user_home_dir().join(".pi").join("agent"))
}

/// Project-local Pi config directory.
pub fn pi_project_dir() -> PathBuf {
    project_root().join(".pi")
}

/// Pi `settings.json` for the chosen scope.
pub fn pi_settings_path(global: bool) -> PathBuf {
    if global {
        pi_global_dir().join("settings.json")
    } else {
        pi_project_dir().join("settings.json")
    }
}

/// Directory where Pi packages installed via vstack land.
pub fn pi_packages_dir(global: bool) -> PathBuf {
    if global {
        pi_global_dir().join("packages")
    } else {
        pi_project_dir().join("packages")
    }
}

/// Directory where vstack symlinks Pi package `bin` entries.
/// Pi expects CLI tools at `<scope>/bin/<name>`.
pub fn pi_bin_dir(global: bool) -> PathBuf {
    if global {
        pi_global_dir().join("bin")
    } else {
        pi_project_dir().join("bin")
    }
}

/// Source index file: per-scope JSON tracking which vstack repo each
/// installed package was copied from, so the extension manager can detect
/// when source-side versions advance and prompt the user to update.
pub fn pi_source_index_path(global: bool) -> PathBuf {
    if global {
        pi_global_dir().join(".vstack-source.json")
    } else {
        pi_project_dir().join(".vstack-source.json")
    }
}

/// Find the project root by walking up from CWD.
/// Looks for `.vstack-lock.json` or harness config dirs.
pub fn project_root() -> PathBuf {
    #[cfg(test)]
    if let Some(root) = crate::test_util::project_root_override() {
        return root;
    }
    static ROOT: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
    ROOT.get_or_init(find_project_root).clone()
}

fn find_project_root() -> PathBuf {
    let Ok(start) = std::env::current_dir() else {
        return PathBuf::from(".");
    };
    find_project_root_within(&start, &user_home_dir())
}

/// Walk up from `start` looking for project markers, refusing to claim `home`
/// itself unless `.vstack-lock.json` lives there. Pure inner function so tests
/// can drive it without touching the real `$HOME`/CWD.
fn find_project_root_within(start: &Path, home: &Path) -> PathBuf {
    // Compare canonical paths so symlinks/aliases don't slip past the home
    // guard. If canonicalize fails, fall back to the literal path.
    let canonical_home = home.canonicalize().unwrap_or_else(|_| home.to_path_buf());
    let mut dir = start.to_path_buf();
    loop {
        // Lock file is the only signal strong enough to override the home
        // guard — its presence means the user explicitly opted this dir in.
        if dir.join(".vstack-lock.json").exists() {
            return dir;
        }
        let canonical_dir = dir.canonicalize().unwrap_or_else(|_| dir.clone());
        let is_home = canonical_dir == canonical_home;
        // ~/.claude, ~/.cursor, etc. are user-scoped harness configs, not
        // project markers. Without this guard, running vstack anywhere under
        // $HOME (outside a real project) treats $HOME itself as the project
        // root and routes project-scope writes into user state.
        if !is_home
            && (dir.join(".claude").is_dir()
                || dir.join(".cursor").is_dir()
                || dir.join(".codex").is_dir()
                || dir.join(".opencode").is_dir()
                || dir.join(".pi").is_dir()
                || dir.join(".agents").is_dir())
        {
            return dir;
        }
        if !dir.pop() {
            break;
        }
    }
    start.to_path_buf()
}

/// Get current timestamp as ISO 8601 string (UTC)
pub fn now_iso() -> String {
    let secs = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    // Manual ISO 8601 without chrono: YYYY-MM-DDTHH:MM:SSZ
    let days = secs / 86400;
    let time_secs = secs % 86400;
    let hours = time_secs / 3600;
    let minutes = (time_secs % 3600) / 60;
    let seconds = time_secs % 60;
    // Days since epoch to date (simplified Gregorian)
    let (year, month, day) = epoch_days_to_date(days);
    format!("{year:04}-{month:02}-{day:02}T{hours:02}:{minutes:02}:{seconds:02}Z")
}

// ── Content hash helpers (FNV-1a — portable, deterministic) ──────

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x00000100000001B3;

fn fnv1a(data: &[u8]) -> u64 {
    let mut h = FNV_OFFSET;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

fn fnv1a_chain(state: u64, data: &[u8]) -> u64 {
    let mut h = state;
    for &b in data {
        h ^= b as u64;
        h = h.wrapping_mul(FNV_PRIME);
    }
    h
}

/// Resolve a Pi extension's source directory by matching the npm package
/// `name` field in `pi-extensions/*/package.json`. Pi extension lock entries
/// store the npm name (e.g. `@vanillagreen/pi-questions`), but the on-disk
/// directory uses an unscoped slug (`pi-extensions/pi-questions`), so a naive
/// `join(entry.name)` never resolves for scoped packages.
fn resolve_pi_extension_dir(source_root: &Path, name: &str) -> Option<PathBuf> {
    let direct = source_root.join("pi-extensions").join(name);
    if direct.is_dir() && direct.join("package.json").is_file() {
        return Some(direct);
    }
    let root = source_root.join("pi-extensions");
    let entries = std::fs::read_dir(&root).ok()?;
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        let pkg = path.join("package.json");
        let Ok(raw) = std::fs::read_to_string(&pkg) else {
            continue;
        };
        let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&raw) else {
            continue;
        };
        if parsed.get("name").and_then(|n| n.as_str()) == Some(name) {
            return Some(path);
        }
    }
    None
}

/// Compute a content hash for a single file. Returns 0 when the file is
/// missing or unreadable, so callers can treat 0 as "absent".
pub(crate) fn hash_file_bytes(path: &Path) -> u64 {
    match std::fs::read(path) {
        Ok(content) => fnv1a(&content),
        Err(_) => 0,
    }
}

/// Compute a content hash for a directory (all files, sorted by relative path).
fn hash_dir_bytes(dir: &Path) -> u64 {
    hash_dir_bytes_excluding(dir, &[])
}

/// Like [`hash_dir_bytes`] but ignores files whose name matches `exclude_files`.
/// Used to compare installed artifacts while skipping volatile bookkeeping
/// files (e.g. the per-process `.vstack-refreshed` marker) that change every
/// run without reflecting a real content change.
pub(crate) fn hash_dir_bytes_excluding(dir: &Path, exclude_files: &[&str]) -> u64 {
    let mut state = FNV_OFFSET;
    let mut walker = walkdir::WalkDir::new(dir)
        .min_depth(1)
        .sort_by_file_name()
        .into_iter();
    while let Some(entry) = walker.next() {
        let Ok(entry) = entry else { continue };
        if entry.file_type().is_dir()
            && should_skip_hash_dir(entry.file_name().to_string_lossy().as_ref())
        {
            walker.skip_current_dir();
            continue;
        }
        if !entry.file_type().is_file() {
            continue;
        }
        if exclude_files
            .iter()
            .any(|name| entry.file_name().to_str() == Some(*name))
        {
            continue;
        }
        // Read content first; if unreadable, skip the entire entry. Folding
        // relpath without content would change the hash whenever a file
        // becomes temporarily unreadable (permission flake, broken symlink),
        // even though source bytes did not change — false-positive staleness.
        let Ok(content) = std::fs::read(entry.path()) else {
            continue;
        };
        let rel = entry.path().strip_prefix(dir).unwrap_or(entry.path());
        state = fnv1a_chain(state, rel.to_string_lossy().as_bytes());
        state = fnv1a_chain(state, &content);
    }
    state
}

fn should_skip_hash_dir(name: &str) -> bool {
    // Keep in sync with verify::should_skip_hash_dir. `.test-output` is
    // pi-claude-bridge's integration-test scratch dir — gitignored, never
    // shipped, and contains symlinks that make verify report false drift.
    matches!(
        name,
        "node_modules"
            | ".git"
            | ".turbo"
            | ".next"
            | ".cache"
            | "build"
            | "out"
            | "coverage"
            | ".pi"
            | ".test-output"
    )
}

/// Extract every line under a `[table]` header from a TOML file. Stops at
/// the next top-level table header. Returns empty bytes if the table or file
/// is missing.
fn extract_toml_table_section(path: &Path, table: &str) -> Vec<u8> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let header = format!("[{}]", table);
    let mut result = Vec::new();
    let mut capturing = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            capturing = trimmed == header;
            continue;
        }
        if capturing {
            result.extend_from_slice(line.as_bytes());
            result.push(b'\n');
        }
    }
    result
}

/// Extract the relevant section for a given name from a TOML file.
/// Returns the raw text of lines belonging to that key, or empty if not found.
/// This avoids hashing the entire config when only one agent/skill's section matters.
fn extract_toml_section_for(path: &Path, name: &str) -> Vec<u8> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    let mut capturing = false;
    for line in content.lines() {
        let trimmed = line.trim();
        // Match: name = ... (start of this key's value)
        if trimmed.starts_with(&format!("{} =", name))
            || trimmed.starts_with(&format!("\"{}\" =", name))
        {
            capturing = true;
            result.extend_from_slice(line.as_bytes());
            result.push(b'\n');
            continue;
        }
        if capturing {
            // Stop at next top-level key or section header
            if trimmed.starts_with('[')
                || (!trimmed.is_empty()
                    && !trimmed.starts_with('#')
                    && !trimmed.starts_with('"')
                    && !trimmed.starts_with('{')
                    && !trimmed.starts_with(']')
                    && !trimmed.starts_with(',')
                    && !line.starts_with(' ')
                    && !line.starts_with('\t'))
            {
                capturing = false;
            } else {
                result.extend_from_slice(line.as_bytes());
                result.push(b'\n');
            }
        }
    }
    result
}

/// Refresh cached repos for all remote sources found in installed lock entries.
/// Called once at TUI startup so staleness checks see the latest content.
pub fn refresh_remote_caches(lock: &LockFile) {
    let mut seen = std::collections::HashSet::new();
    for entry in lock.entries.values() {
        let src = &entry.source;
        // Only remote sources (owner/repo format)
        if src.contains('/') && !src.starts_with('.') && !src.starts_with('/') {
            if !seen.insert(src.clone()) {
                continue;
            }
            let cache_key = src.replace('/', "_");
            let cache_dir = global_base_dir()
                .join(".vstack")
                .join("cache")
                .join(&cache_key);
            if cache_dir.join(".git").exists() {
                let fetch = std::process::Command::new("git")
                    .args(["fetch", "origin", "--quiet"])
                    .current_dir(&cache_dir)
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status();
                if fetch.is_ok_and(|s| s.success()) {
                    let _ = std::process::Command::new("git")
                        .args(["reset", "--hard", "origin/HEAD"])
                        .current_dir(&cache_dir)
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .status();
                }
            }
        }
    }
}

/// Resolve a lock entry's source string to an actual directory path.
/// Handles "." by walking up from CWD to find a vstack source repo,
/// and absolute paths directly.
pub fn resolve_source_path(source: &str) -> Option<PathBuf> {
    crate::refresh_sources::resolve_source_path(source)
}

/// Parse an `owner/repo` slug out of a GitHub SSH/HTTPS remote URL, a bare
/// `owner/repo` shorthand, or `owner/repo.git`. Returns None for local paths,
/// non-GitHub URLs, and anything that is not exactly one owner/repo pair.
pub fn parse_github_slug(url: &str) -> Option<String> {
    let url = url.trim().trim_end_matches('/');

    // Bare `owner/repo` (no scheme, no host, no whitespace): exactly two
    // non-empty, slash-free segments. Local absolute paths and nested relative
    // paths have a leading empty segment or more than two parts.
    if !url.contains("://") && !url.contains('@') && !url.contains(char::is_whitespace) {
        let bare = url.strip_suffix(".git").unwrap_or(url);
        let mut parts = bare.split('/');
        if let (Some(owner), Some(repo), None) = (parts.next(), parts.next(), parts.next())
            && !owner.is_empty()
            && !repo.is_empty()
        {
            return Some(format!(
                "{}/{}",
                owner.to_ascii_lowercase(),
                repo.to_ascii_lowercase()
            ));
        }
        return None;
    }

    let after = url
        .strip_prefix("git@github.com:")
        .or_else(|| url.strip_prefix("https://github.com/"))
        .or_else(|| url.strip_prefix("ssh://git@github.com/"))?;
    let after = after
        .trim_end_matches('/')
        .strip_suffix(".git")
        .unwrap_or(after);
    let mut parts = after.split('/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    if owner.is_empty() || repo.is_empty() || parts.next().is_some() {
        return None;
    }
    Some(format!(
        "{}/{}",
        owner.to_ascii_lowercase(),
        repo.to_ascii_lowercase()
    ))
}

pub fn github_slug_eq(left: &str, right: &str) -> bool {
    parse_github_slug(left)
        .zip(parse_github_slug(right))
        .is_some_and(|(left, right)| left == right)
}

fn source_repo_from_git_origin(source_root: &Path) -> Option<String> {
    let output = std::process::Command::new("git")
        .args(["-C", source_root.to_str()?, "remote", "get-url", "origin"])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&output.stdout);
    parse_github_slug(url.trim())
}

/// Resolve the durable repository identity for a source. Prefer the actual Git
/// origin of a local/cached source root; fall back to the recorded source string
/// only when it is itself a GitHub remote URL or owner/repo shorthand.
pub fn source_repo_for_source(source_root: Option<&Path>, recorded_source: &str) -> Option<String> {
    source_root
        .and_then(source_repo_from_git_origin)
        .or_else(|| parse_github_slug(recorded_source))
}

/// Compute source hash for a lock entry based on its kind.
pub fn compute_source_hash(entry: &LockEntry) -> String {
    let source_root = match resolve_source_path(&entry.source) {
        Some(p) => p,
        None => return String::new(),
    };
    let proj_root = project_root();

    let mut state = FNV_OFFSET;

    match entry.kind {
        ItemKind::Skill => {
            let dir = source_root.join("skills").join(&entry.name);
            if dir.exists() {
                state = fnv1a_chain(state, &hash_dir_bytes(&dir).to_le_bytes());
            }
            // Only hash this skill's section from project vstack.toml
            let project_config = proj_root.join("vstack.toml");
            let section = extract_toml_section_for(&project_config, &entry.name);
            if !section.is_empty() {
                state = fnv1a_chain(state, &section);
            }
        }
        ItemKind::Agent => {
            let file = source_root
                .join("agents")
                .join(format!("{}.md", entry.name));
            if file.exists() {
                state = fnv1a_chain(state, &hash_file_bytes(&file).to_le_bytes());
            }
            // Hash this agent's sections from both configs
            let source_config = source_root.join("vstack.toml");
            for config_path in [&source_config, &proj_root.join("vstack.toml")] {
                let section = extract_toml_section_for(config_path, &entry.name);
                if !section.is_empty() {
                    state = fnv1a_chain(state, &section);
                }
            }
        }
        ItemKind::Hook => {
            let file = source_root.join("hooks").join(format!("{}.sh", entry.name));
            if file.exists() {
                state = fnv1a_chain(state, &hash_file_bytes(&file).to_le_bytes());
            }
            // Hook attribution lives in source vstack.toml [hook-events]
            // (keyed by event:matcher, not hook name). Re-targeting a hook —
            // e.g. "PostToolUse:Edit|Write" = ["engineer"] → "all" — must mark
            // the hook stale even when the .sh file is unchanged. Hash the
            // entire table so any role-list change invalidates every hook;
            // re-running refresh is cheap, missing the change is not.
            let source_config = source_root.join("vstack.toml");
            let section = extract_toml_table_section(&source_config, "hook-events");
            if !section.is_empty() {
                state = fnv1a_chain(state, &section);
            }
        }
        ItemKind::PiExtension => {
            if let Some(dir) = resolve_pi_extension_dir(&source_root, &entry.name) {
                state = fnv1a_chain(state, &hash_dir_bytes(&dir).to_le_bytes());
            }
        }
        ItemKind::Extra => {
            let dir = source_root.join("extras").join(&entry.name);
            if dir.exists() {
                state = fnv1a_chain(state, &hash_dir_bytes(&dir).to_le_bytes());
            }
        }
    }

    format!("{:016x}", state)
}

/// Check if an entry's source has changed since install.
/// Uses content hash (immune to git mtime resets).
/// Falls back to "not outdated" if no hash stored (old lock format).
pub fn is_source_changed(entry: &LockEntry) -> bool {
    if entry.source_hash.is_empty() {
        return false; // No hash stored — assume fresh (legacy lock)
    }
    let current = compute_source_hash(entry);
    current != entry.source_hash
}

/// Discovered item on disk that was installed by vstack.
#[derive(Debug)]
pub struct DiskItem {
    pub name: String,
    pub kind: ItemKind,
}

/// Discovered hook artifacts on disk that match hooks available in the source.
#[derive(Debug)]
struct DiskHookItem {
    name: String,
    harnesses: Vec<String>,
}

/// Scan the canonical skill directory for skills installed by vstack.
/// Skills are identified by the `.vstack-refreshed` marker; hook recovery
/// uses concrete per-harness hook artifacts plus matching source hooks.
pub fn scan_installed_skills_on_disk(global: bool) -> Vec<DiskItem> {
    let mut items = Vec::new();

    // Canonical skill location: .agents/skills/<name>/
    let canonical_skills = if global {
        vec![
            global_state_dir().join("skills"),
            codex_home_dir().join("skills"),
        ]
    } else {
        vec![project_root().join(".agents").join("skills")]
    };

    let mut seen = std::collections::HashSet::new();
    for skills_dir in canonical_skills {
        if !skills_dir.is_dir() {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(&skills_dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            // Only count directories with a .vstack-refreshed marker
            if !path.join(".vstack-refreshed").exists() {
                continue;
            }
            if let Some(name) = path.file_name().and_then(|n| n.to_str())
                && seen.insert(name.to_string())
            {
                items.push(DiskItem {
                    name: name.to_string(),
                    kind: ItemKind::Skill,
                });
            }
        }
    }

    items
}

fn scan_installed_hooks_on_disk_at(
    project_root: &Path,
    global: bool,
    source: &str,
) -> Vec<DiskHookItem> {
    let cursor_global_rules_dir = cursor_global_dir().join("rules");
    scan_installed_hooks_on_disk_at_with_cursor_global_rules(
        project_root,
        global,
        source,
        &cursor_global_rules_dir,
    )
}

fn scan_installed_hooks_on_disk_at_with_cursor_global_rules(
    project_root: &Path,
    global: bool,
    source: &str,
    cursor_global_rules_dir: &Path,
) -> Vec<DiskHookItem> {
    let Some(source_root) = resolve_source_path(source) else {
        return Vec::new();
    };

    let Ok(source_hooks) = crate::hook::discover_hooks(&source_root.join("hooks")) else {
        return Vec::new();
    };

    source_hooks
        .into_iter()
        .filter_map(|hook| {
            let harnesses = installed_hook_harnesses_on_disk(
                project_root,
                global,
                &hook,
                cursor_global_rules_dir,
            );
            if harnesses.is_empty() {
                None
            } else {
                Some(DiskHookItem {
                    name: hook.name,
                    harnesses,
                })
            }
        })
        .collect()
}

fn installed_hook_harnesses_on_disk(
    project_root: &Path,
    global: bool,
    hook: &crate::hook::Hook,
    cursor_global_rules_dir: &Path,
) -> Vec<String> {
    let mut harnesses = Vec::new();

    if hook.applies_to(crate::harness::Harness::ClaudeCode.id())
        && claude_hook_artifact_exists(project_root, global, hook)
    {
        harnesses.push(crate::harness::Harness::ClaudeCode.id().to_string());
    }
    if hook.applies_to(crate::harness::Harness::Cursor.id())
        && cursor_hook_artifact_exists(project_root, global, hook, cursor_global_rules_dir)
    {
        harnesses.push(crate::harness::Harness::Cursor.id().to_string());
    }
    if hook.applies_to(crate::harness::Harness::OpenCode.id())
        && opencode_hook_artifact_exists(project_root, global, hook)
    {
        harnesses.push(crate::harness::Harness::OpenCode.id().to_string());
    }
    if hook.applies_to(crate::harness::Harness::Codex.id())
        && codex_hook_artifact_exists(project_root, global, hook)
    {
        harnesses.push(crate::harness::Harness::Codex.id().to_string());
    }
    // Pi has no per-hook artifact to recover. Hooks are bundled in the
    // @vanillagreen/pi-hooks package, which is recovered as a Pi package.

    harnesses
}

fn generated_safety_action_line(hook: &crate::hook::Hook) -> Option<String> {
    hook.safety_prose().lines().last().map(str::to_string)
}

fn hook_script_artifact_matches(path: &Path, hook: &crate::hook::Hook, harness_id: &str) -> bool {
    if std::fs::read(path).is_ok_and(|installed| installed == hook.script.as_bytes()) {
        return true;
    }

    crate::hook::Hook::from_file(path).is_ok_and(|installed| {
        installed.name == hook.name
            && installed.event == hook.event
            && installed.matcher == hook.matcher
            && installed.applies_to(harness_id)
    })
}

fn safety_text_artifact_matches(
    path: &Path,
    expected: &str,
    header_line: &str,
    action_line: &str,
) -> bool {
    if std::fs::read(path).is_ok_and(|installed| installed == expected.as_bytes()) {
        return true;
    }

    std::fs::read_to_string(path)
        .is_ok_and(|content| generated_safety_text_matches(&content, header_line, action_line))
}

fn generated_safety_text_matches(content: &str, header_line: &str, action_line: &str) -> bool {
    content.lines().any(|line| line == header_line)
        && content.lines().any(|line| line == action_line)
}

fn claude_hook_artifact_exists(
    project_root: &Path,
    global: bool,
    hook: &crate::hook::Hook,
) -> bool {
    let hooks_dir = if global {
        claude_global_dir().join("hooks")
    } else {
        project_root.join(".claude").join("hooks")
    };
    hook_script_artifact_matches(
        &hooks_dir.join(format!("{}.sh", hook.name)),
        hook,
        crate::harness::Harness::ClaudeCode.id(),
    )
}

fn cursor_hook_artifact_exists(
    project_root: &Path,
    global: bool,
    hook: &crate::hook::Hook,
    cursor_global_rules_dir: &Path,
) -> bool {
    if global && !crate::harness::Harness::Cursor.supports_global_scope() {
        return false;
    }

    let project_rules_dir = project_root.join(".cursor").join("rules");
    let rules_dir = if global {
        cursor_global_rules_dir
    } else {
        &project_rules_dir
    };
    let expected = crate::installer::cursor_hook_rule_contents(hook);
    generated_safety_action_line(hook).is_some_and(|action_line| {
        safety_text_artifact_matches(
            &rules_dir.join(format!("safety-{}.mdc", hook.name)),
            &expected,
            &format!("# Safety: {}", hook.name),
            &action_line,
        )
    })
}

fn codex_hook_artifact_exists(project_root: &Path, global: bool, hook: &crate::hook::Hook) -> bool {
    let root = if global {
        codex_home_dir()
    } else {
        project_root.join(".codex")
    };

    if crate::installer::codex_event_for(&hook.event).is_some() {
        return hook_script_artifact_matches(
            &root.join("hooks").join(format!("{}.sh", hook.name)),
            hook,
            crate::harness::Harness::Codex.id(),
        );
    }

    codex_agent_has_expected_prose(&root, hook)
}

fn codex_agent_has_expected_prose(codex_root: &Path, hook: &crate::hook::Hook) -> bool {
    let agents_dir = codex_root.join("agents");
    let Ok(entries) = std::fs::read_dir(&agents_dir) else {
        return false;
    };
    let marker = format!("## Safety: {}", hook.name);
    let Some(action_line) = generated_safety_action_line(hook) else {
        return false;
    };
    entries.flatten().any(|entry| {
        let path = entry.path();
        path.extension().is_some_and(|ex| ex == "toml")
            && std::fs::read_to_string(&path)
                .map(|content| generated_safety_text_matches(&content, &marker, &action_line))
                .unwrap_or(false)
    })
}

fn opencode_hook_artifact_exists(
    project_root: &Path,
    global: bool,
    hook: &crate::hook::Hook,
) -> bool {
    let instructions_dir = if global {
        opencode_global_dir().join("instructions")
    } else {
        project_root.join(".opencode").join("instructions")
    };
    let expected = crate::installer::opencode_hook_instruction_contents(hook);
    generated_safety_action_line(hook).is_some_and(|action_line| {
        safety_text_artifact_matches(
            &instructions_dir.join(format!("vstack-hook-{}.md", hook.name)),
            &expected,
            &format!("# Safety: {}", hook.name),
            &action_line,
        )
    })
}

fn normalize_path_lexical(path: &Path) -> PathBuf {
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

fn managed_skill_roots(global: bool) -> Vec<PathBuf> {
    if global {
        vec![
            global_state_dir().join("skills"),
            codex_home_dir().join("skills"),
        ]
    } else {
        vec![project_root().join(".agents").join("skills")]
    }
}

fn harness_skill_dirs(global: bool) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for harness in crate::harness::Harness::ALL {
        let dir = harness.skills_dir(global);
        let key = normalize_path_lexical(&dir);
        if seen.insert(key) {
            dirs.push(dir);
        }
    }
    dirs
}

fn prune_broken_skill_symlinks_in_dirs(dirs: &[PathBuf], managed_roots: &[PathBuf]) -> bool {
    let managed_roots: Vec<PathBuf> = managed_roots
        .iter()
        .map(|root| normalize_path_lexical(root))
        .collect();
    let mut modified = false;

    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_symlink() || path.exists() {
                continue;
            }

            let Ok(target) = std::fs::read_link(&path) else {
                continue;
            };
            let target = if target.is_absolute() {
                target
            } else {
                path.parent().unwrap_or(dir).join(target)
            };
            let target = normalize_path_lexical(&target);

            if !managed_roots.iter().any(|root| target.starts_with(root)) {
                continue;
            }

            if std::fs::remove_file(&path).is_ok() {
                eprintln!("  Removed stale skill symlink: {}", path.display());
                modified = true;
            }
        }
    }

    modified
}

fn prune_broken_skill_symlinks(global: bool) -> bool {
    let dirs = harness_skill_dirs(global);
    let roots = managed_skill_roots(global);
    prune_broken_skill_symlinks_in_dirs(&dirs, &roots)
}

fn harness_skill_dirs_with_ids(global: bool) -> Vec<(String, PathBuf)> {
    crate::harness::Harness::ALL
        .iter()
        .map(|harness| (harness.id().to_string(), harness.skills_dir(global)))
        .collect()
}

fn is_managed_skill_symlink(path: &Path, managed_roots: &[PathBuf]) -> bool {
    if !path.is_symlink() {
        return false;
    }
    let Ok(target) = std::fs::read_link(path) else {
        return false;
    };
    let target = if target.is_absolute() {
        target
    } else {
        path.parent().unwrap_or_else(|| Path::new(".")).join(target)
    };
    let target = normalize_path_lexical(&target);
    let managed_roots: Vec<PathBuf> = managed_roots
        .iter()
        .map(|root| normalize_path_lexical(root))
        .collect();
    managed_roots.iter().any(|root| target.starts_with(root))
}

fn migrate_copy_skill_lock_entries_with_symlink_mirrors(
    lock: &mut LockFile,
    harness_skill_dirs: &[(String, PathBuf)],
    managed_roots: &[PathBuf],
) -> bool {
    let mut modified = false;
    for entry in lock.entries.values_mut() {
        if entry.kind != ItemKind::Skill || entry.method != InstallMethod::Copy {
            continue;
        }
        let has_managed_symlink = entry.harnesses.iter().any(|harness_id| {
            harness_skill_dirs
                .iter()
                .filter(|(id, _)| id == harness_id)
                .any(|(_, dir)| is_managed_skill_symlink(&dir.join(&entry.name), managed_roots))
        });
        if !has_managed_symlink {
            continue;
        }
        entry.method = InstallMethod::Symlink;
        entry.source_hash = compute_source_hash(entry);
        eprintln!(
            "  Migrated skill lock entry to symlink mode: {}",
            entry.name
        );
        modified = true;
    }
    modified
}

fn migrate_copy_skill_lock_entries_with_symlink_mirrors_for_scope(
    lock: &mut LockFile,
    global: bool,
) -> bool {
    let harness_skill_dirs = harness_skill_dirs_with_ids(global);
    let managed_roots = managed_skill_roots(global);
    migrate_copy_skill_lock_entries_with_symlink_mirrors(lock, &harness_skill_dirs, &managed_roots)
}

// Recover only concrete hook artifacts with stable vstack-generated identity.
// Scripts must carry matching hook frontmatter; wrapper/prose artifacts must
// carry the exact safety header line plus the event/matcher-derived action
// line. This allows stale artifacts after source edits to regain a lock entry
// so refresh can replace them. Pi has no per-hook artifact; Pi hook behavior is
// packaged and recovered through the Pi package lock path.
fn recover_hook_lock_entries_at(
    lock: &mut LockFile,
    project_root: &Path,
    global: bool,
    source: &str,
    installed_at: &str,
) -> bool {
    let cursor_global_rules_dir = cursor_global_dir().join("rules");
    recover_hook_lock_entries_at_with_cursor_global_rules(
        lock,
        project_root,
        global,
        source,
        installed_at,
        &cursor_global_rules_dir,
    )
}

fn recover_hook_lock_entries_at_with_cursor_global_rules(
    lock: &mut LockFile,
    project_root: &Path,
    global: bool,
    source: &str,
    installed_at: &str,
    cursor_global_rules_dir: &Path,
) -> bool {
    let source_repo = source_repo_for_source(resolve_source_path(source).as_deref(), source);
    let mut modified = false;
    for item in scan_installed_hooks_on_disk_at_with_cursor_global_rules(
        project_root,
        global,
        source,
        cursor_global_rules_dir,
    ) {
        match lock.entries.get_mut(&item.name) {
            Some(entry) if entry.kind == ItemKind::Hook => {
                if entry.source_repo.is_none() && source_repo.is_some() {
                    entry.source_repo = source_repo.clone();
                    modified = true;
                }
                for harness in item.harnesses {
                    if !entry.harnesses.contains(&harness) {
                        entry.harnesses.push(harness);
                        modified = true;
                    }
                }
            }
            Some(_) => {}
            None => {
                let entry = LockEntry {
                    name: item.name.clone(),
                    kind: ItemKind::Hook,
                    source: source.to_string(),
                    source_repo: source_repo.clone(),
                    harnesses: item.harnesses,
                    method: InstallMethod::Copy,
                    installed_at: installed_at.to_string(),
                    source_hash: String::new(),
                };
                eprintln!("  Recovered lock entry for installed hook: {}", item.name);
                lock.add(entry);
                modified = true;
            }
        }
    }
    modified
}

/// Reconcile the lock file with what's actually on disk.
///
/// - Skills on disk (with `.vstack-refreshed` marker) but missing from lock are
///   re-added.
/// - Hook artifacts on disk with stable vstack-generated identity are
///   re-added: Claude/Codex native scripts with matching hook frontmatter,
///   Cursor safety rules, OpenCode instruction files, and Codex prose fallback
///   blocks with exact safety header and event/matcher action lines. Pi has no
///   per-hook artifact because hooks are delivered by the Pi hooks package.
/// - Items in lock but missing from disk are removed from lock.
/// - Broken harness skill symlinks pointing at vstack's canonical skill roots
///   are removed so generated `.claude/skills/*` entries cannot survive with
///   missing `.agents/skills/*` targets.
/// - Returns true if the lock was modified.
pub fn reconcile_lock_with_disk(lock: &mut LockFile, global: bool, source: &str) -> bool {
    let mut modified = false;

    if prune_broken_skill_symlinks(global) {
        modified = true;
    }
    if migrate_copy_skill_lock_entries_with_symlink_mirrors_for_scope(lock, global) {
        modified = true;
    }

    // Re-add skills found on disk but missing from lock
    let disk_skills = scan_installed_skills_on_disk(global);
    let now = now_iso();
    let source_repo = source_repo_for_source(resolve_source_path(source).as_deref(), source);
    for item in &disk_skills {
        if !lock.entries.contains_key(&item.name) {
            // Determine which harnesses have this skill by checking dirs
            let mut harnesses = Vec::new();
            for harness in crate::harness::Harness::ALL {
                let skill_path = harness.skills_dir(global).join(&item.name);
                if skill_path.exists() || skill_path.is_symlink() {
                    harnesses.push(harness.id().to_string());
                }
            }
            if harnesses.is_empty() {
                // At minimum it's in the canonical location
                harnesses.push("claude-code".to_string());
            }
            let mut entry = LockEntry {
                name: item.name.clone(),
                kind: item.kind,
                source: source.to_string(),
                source_repo: source_repo.clone(),
                harnesses,
                method: InstallMethod::Symlink,
                installed_at: now.clone(),
                source_hash: String::new(),
            };
            entry.source_hash = compute_source_hash(&entry);
            eprintln!("  Recovered lock entry for installed skill: {}", item.name);
            lock.add(entry);
            modified = true;
        }
    }

    // Remove lock entries for skills whose files no longer exist on disk
    let disk_names: std::collections::HashSet<&str> =
        disk_skills.iter().map(|d| d.name.as_str()).collect();
    let stale_skills: Vec<String> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Skill && !disk_names.contains(e.name.as_str()))
        .map(|(name, _)| name.clone())
        .collect();
    for name in stale_skills {
        // Verify the canonical dir is actually gone (not just missing the marker)
        let canonical = if global {
            global_state_dir().join("skills").join(&name)
        } else {
            project_root().join(".agents").join("skills").join(&name)
        };
        if !canonical.exists() {
            eprintln!("  Removed stale lock entry (files missing): {name}");
            lock.remove(&name);
            modified = true;
        }
    }

    let root = project_root();
    if recover_hook_lock_entries_at(lock, &root, global, source, &now) {
        modified = true;
    }

    // Remove stale Pi package lock entries. Pi packages do not have the skill
    // marker file; their on-disk truth is the deployed package directory and/or
    // a matching settings.json packages entry.
    let stale_pi_extensions: Vec<String> = lock
        .entries
        .iter()
        .filter(|(_, e)| {
            e.kind == ItemKind::PiExtension
                && !crate::pi_extension::is_pi_extension_installed(&e.name, global)
        })
        .map(|(name, _)| name.clone())
        .collect();
    for name in stale_pi_extensions {
        eprintln!("  Removed stale lock entry (Pi package missing): {name}");
        lock.remove(&name);
        modified = true;
    }

    // Re-add Pi packages found on disk but missing from the lock. Source of
    // truth: <scope>/.vstack-source.json — every entry there was placed by
    // vstack and records its origin repo. Skills already get this recovery
    // path; without it Pi extensions silently disappear from `vstack list`
    // and refresh after a lost lock file.
    if let Ok(source_index) = crate::pi_extension::read_source_index(global) {
        for (pkg_name, idx_entry) in &source_index {
            if lock.entries.contains_key(pkg_name) {
                continue;
            }
            if !crate::pi_extension::is_pi_extension_installed(pkg_name, global) {
                continue;
            }
            let entry_source = idx_entry
                .source_repo
                .clone()
                .unwrap_or_else(|| source.to_string());
            let entry_source_repo = source_repo_for_source(
                resolve_source_path(&entry_source).as_deref(),
                &entry_source,
            );
            let mut entry = LockEntry {
                name: pkg_name.clone(),
                kind: ItemKind::PiExtension,
                source: entry_source,
                source_repo: entry_source_repo,
                harnesses: vec!["pi".to_string()],
                method: InstallMethod::Copy,
                installed_at: now.clone(),
                source_hash: String::new(),
            };
            entry.source_hash = compute_source_hash(&entry);
            eprintln!("  Recovered lock entry for installed pi-package: {pkg_name}");
            lock.add(entry);
            modified = true;
        }
    }

    modified
}

fn epoch_days_to_date(days: u64) -> (u64, u64, u64) {
    // Algorithm from http://howardhinnant.github.io/date_algorithms.html
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (y, m, d)
}

#[cfg(test)]
mod source_registry_tests {
    use super::*;
    use std::fs;

    fn sandbox(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "vstack_source_registry_{label}_{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn init_git_origin(dir: &Path, origin: &str) {
        let status = std::process::Command::new("git")
            .args(["init", "-q"])
            .current_dir(dir)
            .status()
            .unwrap();
        assert!(status.success());
        let status = std::process::Command::new("git")
            .args(["remote", "add", "origin", origin])
            .current_dir(dir)
            .status()
            .unwrap();
        assert!(status.success());
    }

    #[test]
    fn lock_entry_deserializes_legacy_without_source_repo() {
        let raw = r#"{
          "name": "guard",
          "kind": "hook",
          "source": "/missing/source",
          "harnesses": ["codex"],
          "method": "copy",
          "installed_at": "2026-07-21T00:00:00Z"
        }"#;
        let entry: LockEntry = serde_json::from_str(raw).unwrap();
        assert_eq!(entry.name, "guard");
        assert_eq!(entry.kind, ItemKind::Hook);
        assert!(entry.source_repo.is_none());
        assert!(entry.source_hash.is_empty());
    }

    #[test]
    fn source_repo_for_source_prefers_git_origin_over_layout() {
        let dir = sandbox("source_repo_git");
        fs::create_dir_all(dir.join("agents")).unwrap();
        fs::create_dir_all(dir.join("hooks")).unwrap();
        init_git_origin(&dir, "https://github.com/vanillagreencom/vstack.git");

        assert_eq!(
            source_repo_for_source(Some(&dir), &dir.to_string_lossy()).as_deref(),
            Some("vanillagreencom/vstack")
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn source_repo_for_source_does_not_infer_from_local_layout_only() {
        let dir = sandbox("source_repo_layout");
        fs::create_dir_all(dir.join("agents")).unwrap();
        fs::create_dir_all(dir.join("hooks")).unwrap();

        assert_eq!(
            source_repo_for_source(Some(&dir), &dir.to_string_lossy()),
            None
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn parse_github_slug_normalizes_supported_remote_shapes() {
        assert_eq!(
            parse_github_slug("git@github.com:VanillaGreenCom/VStack.git").as_deref(),
            Some("vanillagreencom/vstack")
        );
        assert_eq!(
            parse_github_slug("https://github.com/owner/repo/").as_deref(),
            Some("owner/repo")
        );
        assert_eq!(parse_github_slug("a/b/c"), None);
        assert_eq!(parse_github_slug("/home/me/dev/vstack"), None);
    }

    #[test]
    fn prune_drops_dead_absolute_paths_keeps_shorthand_and_live_paths() {
        let dir = sandbox("prune_drops_dead");
        let live = dir.join("live");
        fs::create_dir_all(&live).unwrap();
        let dead = dir.join("dead");
        // dead is intentionally not created.

        let mut reg = SourceRegistry {
            current: Some("vanillagreencom/vstack".to_string()),
            entries: vec![
                "vanillagreencom/vstack".to_string(),
                live.display().to_string(),
                dead.display().to_string(),
                "https://example.com/repo".to_string(),
            ],
            ..Default::default()
        };
        let pruned = reg.prune_dead_paths();
        assert_eq!(pruned, 1);
        assert_eq!(
            reg.entries,
            vec![
                "vanillagreencom/vstack".to_string(),
                live.display().to_string(),
                "https://example.com/repo".to_string(),
            ]
        );
        assert_eq!(reg.current.as_deref(), Some("vanillagreencom/vstack"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn prune_clears_current_if_current_is_dead() {
        let dir = sandbox("prune_clears_current");
        let dead = dir.join("dead");
        let mut reg = SourceRegistry {
            current: Some(dead.display().to_string()),
            entries: vec![dead.display().to_string()],
            ..Default::default()
        };
        let pruned = reg.prune_dead_paths();
        assert_eq!(pruned, 1);
        assert!(reg.current.is_none());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn load_persists_pruned_view_to_disk() {
        let dir = sandbox("load_persists");
        let path = dir.join("sources.json");
        let dead = dir.join("dead-source").display().to_string();
        let raw = serde_json::json!({
            "current": "vanillagreencom/vstack",
            "entries": ["vanillagreencom/vstack", dead],
        });
        fs::write(&path, raw.to_string()).unwrap();

        let loaded = SourceRegistry::load(&path).unwrap();
        assert_eq!(loaded.entries, vec!["vanillagreencom/vstack".to_string()]);

        let on_disk: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(on_disk["entries"].as_array().unwrap().len(), 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn remember_ignores_temp_sources() {
        let dir = sandbox("remember_temp");
        let mut reg = SourceRegistry::default();

        reg.remember("vanillagreencom/vstack");
        reg.remember(&dir.display().to_string());

        assert_eq!(reg.current.as_deref(), Some("vanillagreencom/vstack"));
        assert_eq!(reg.entries, vec!["vanillagreencom/vstack".to_string()]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn remember_for_project_does_not_change_global_current() {
        let project_a = sandbox("project_a");
        let project_b = sandbox("project_b");
        let mut reg = SourceRegistry::default();

        reg.remember("vanillagreencom/vstack");
        reg.remember_for_project(&project_a, "owner/a");
        reg.remember_for_project(&project_b, "owner/b");

        assert_eq!(reg.current.as_deref(), Some("vanillagreencom/vstack"));
        assert_eq!(reg.current_for_project(&project_a), Some("owner/a"));
        assert_eq!(reg.current_for_project(&project_b), Some("owner/b"));
        assert!(reg.entries.contains(&"owner/a".to_string()));
        assert!(reg.entries.contains(&"owner/b".to_string()));
        let _ = fs::remove_dir_all(&project_a);
        let _ = fs::remove_dir_all(&project_b);
    }

    #[test]
    fn forget_clears_matching_project_current() {
        let project = sandbox("forget_project");
        let mut reg = SourceRegistry::default();
        reg.remember_for_project(&project, "owner/repo");

        reg.forget("owner/repo");

        assert_eq!(reg.current_for_project(&project), None);
        assert!(!reg.entries.contains(&"owner/repo".to_string()));
        let _ = fs::remove_dir_all(&project);
    }

    #[test]
    fn forget_records_removed_source_tombstone() {
        let mut reg = SourceRegistry::default();

        reg.forget("vanillagreencom/vstack");

        assert!(reg.was_removed("vanillagreencom/vstack"));
    }

    #[test]
    fn pi_extension_hash_tracks_scoped_package_content() {
        let dir = sandbox("pi_hash_scoped");
        let pkg_dir = dir.join("pi-extensions").join("pi-questions");
        fs::create_dir_all(&pkg_dir).unwrap();
        fs::write(
            pkg_dir.join("package.json"),
            r#"{"name":"@vanillagreen/pi-questions","version":"0.0.1"}"#,
        )
        .unwrap();
        let ext_dir = pkg_dir.join("extensions");
        fs::create_dir_all(&ext_dir).unwrap();
        fs::write(ext_dir.join("questions.ts"), b"// before").unwrap();

        let entry = LockEntry {
            name: "@vanillagreen/pi-questions".to_string(),
            kind: ItemKind::PiExtension,
            source: dir.display().to_string(),
            source_repo: None,
            harnesses: vec!["pi".to_string()],
            method: InstallMethod::Symlink,
            installed_at: "2026-05-06T00:00:00Z".to_string(),
            source_hash: String::new(),
        };

        let h1 = compute_source_hash(&entry);
        fs::write(ext_dir.join("questions.ts"), b"// after a real edit").unwrap();
        let h2 = compute_source_hash(&entry);

        assert_ne!(
            h1, h2,
            "hash must change when source content changes for scoped Pi packages"
        );
        // Must not collapse to the bare FNV offset constant.
        assert_ne!(h1, format!("{:016x}", FNV_OFFSET));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn find_project_root_refuses_home_with_only_user_harness_dirs() {
        let dir = sandbox("find_root_home");
        let fake_home = dir.join("home");
        fs::create_dir_all(fake_home.join(".claude")).unwrap();
        fs::create_dir_all(fake_home.join(".pi")).unwrap();
        let workdir = fake_home.join("random-non-project");
        fs::create_dir_all(&workdir).unwrap();

        let root = find_project_root_within(&workdir, &fake_home);
        assert_eq!(
            root, workdir,
            "$HOME with .claude/.pi must NOT be claimed as project root; fall back to CWD"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn find_project_root_accepts_home_when_lock_file_present() {
        let dir = sandbox("find_root_home_lock");
        let fake_home = dir.join("home");
        fs::create_dir_all(&fake_home).unwrap();
        fs::write(fake_home.join(".vstack-lock.json"), "{}").unwrap();
        let workdir = fake_home.join("sub");
        fs::create_dir_all(&workdir).unwrap();

        let root = find_project_root_within(&workdir, &fake_home);
        assert_eq!(
            root.canonicalize().unwrap(),
            fake_home.canonicalize().unwrap(),
            "explicit lock file at $HOME overrides the home guard"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn find_project_root_finds_real_project_under_home() {
        let dir = sandbox("find_root_real_project");
        let fake_home = dir.join("home");
        fs::create_dir_all(fake_home.join(".claude")).unwrap();
        let project = fake_home.join("work").join("app");
        fs::create_dir_all(project.join(".claude")).unwrap();
        let workdir = project.join("src");
        fs::create_dir_all(&workdir).unwrap();

        let root = find_project_root_within(&workdir, &fake_home);
        assert_eq!(
            root, project,
            "real project under $HOME should still be detected"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hook_hash_tracks_hook_events_table_changes() {
        let dir = sandbox("hook_hash_events");
        fs::create_dir_all(dir.join("hooks")).unwrap();
        fs::write(
            dir.join("hooks").join("my-hook.sh"),
            b"#!/usr/bin/env bash\necho hi\n",
        )
        .unwrap();
        fs::write(
            dir.join("vstack.toml"),
            "[hook-events]\n\"PostToolUse:Edit|Write\" = [\"engineer\"]\n",
        )
        .unwrap();

        let entry = LockEntry {
            name: "my-hook".to_string(),
            kind: ItemKind::Hook,
            source: dir.display().to_string(),
            source_repo: None,
            harnesses: vec!["claude-code".to_string()],
            method: InstallMethod::Symlink,
            installed_at: "2026-05-09T00:00:00Z".to_string(),
            source_hash: String::new(),
        };
        let h1 = compute_source_hash(&entry);

        // Re-target the hook without touching the .sh file.
        fs::write(
            dir.join("vstack.toml"),
            "[hook-events]\n\"PostToolUse:Edit|Write\" = \"all\"\n",
        )
        .unwrap();
        let h2 = compute_source_hash(&entry);

        assert_ne!(
            h1, h2,
            "changing [hook-events] role list must invalidate hook source hash"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    fn test_hook_script(name: &str, body: &str) -> String {
        test_hook_script_with_event(name, "PreToolUse", body)
    }

    fn test_hook_script_with_event(name: &str, event: &str, body: &str) -> String {
        test_hook_script_with_meta(name, event, "Bash", "test hook", body)
    }

    fn test_hook_script_with_meta(
        name: &str,
        event: &str,
        matcher: &str,
        description: &str,
        body: &str,
    ) -> String {
        format!(
            "# ---
# name: {name}
# event: {event}
# matcher: {matcher}
# description: {description}
# ---
#!/usr/bin/env bash
{body}
"
        )
    }

    #[test]
    fn scan_installed_hooks_on_disk_detects_concrete_project_artifacts() {
        let dir = sandbox("hook_scan_artifacts");
        let source = dir.join("source");
        let project = dir.join("project");
        fs::create_dir_all(source.join("hooks")).unwrap();
        let script = test_hook_script("my-hook", "echo source");
        let source_hook_path = source.join("hooks").join("my-hook.sh");
        fs::write(&source_hook_path, &script).unwrap();
        let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();

        fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
        fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();
        fs::create_dir_all(project.join(".cursor").join("rules")).unwrap();
        fs::write(
            project.join(".cursor/rules/safety-my-hook.mdc"),
            crate::installer::cursor_hook_rule_contents(&hook),
        )
        .unwrap();
        fs::create_dir_all(project.join(".codex").join("hooks")).unwrap();
        fs::write(project.join(".codex/hooks/my-hook.sh"), &script).unwrap();
        fs::create_dir_all(project.join(".opencode").join("instructions")).unwrap();
        fs::write(
            project.join(".opencode/instructions/vstack-hook-my-hook.md"),
            crate::installer::opencode_hook_instruction_contents(&hook),
        )
        .unwrap();

        let items = scan_installed_hooks_on_disk_at(&project, false, &source.display().to_string());

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].name, "my-hook");
        let mut harnesses = items[0].harnesses.clone();
        harnesses.sort();
        assert_eq!(
            harnesses,
            vec![
                "claude-code".to_string(),
                "codex".to_string(),
                "cursor".to_string(),
                "opencode".to_string()
            ]
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_sets_empty_hash_for_refresh_summary() {
        let dir = sandbox("hook_recover_lock");
        let source = dir.join("source");
        let project = dir.join("project");
        fs::create_dir_all(source.join("hooks")).unwrap();
        let script = test_hook_script("my-hook", "echo source");
        fs::write(source.join("hooks").join("my-hook.sh"), &script).unwrap();
        fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
        fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();
        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };

        let modified = recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        );

        assert!(modified);
        let entry = lock.entries.get("my-hook").unwrap();
        assert_eq!(entry.kind, ItemKind::Hook);
        assert_eq!(entry.harnesses, vec!["claude-code".to_string()]);
        assert_eq!(entry.method, InstallMethod::Copy);
        assert!(
            entry.source_hash.is_empty(),
            "refresh should count recovered hooks as updated after reinstall"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_recovers_stale_script_after_source_change() {
        let dir = sandbox("hook_recover_stale_script");
        let source = dir.join("source");
        let project = dir.join("project");
        fs::create_dir_all(source.join("hooks")).unwrap();
        fs::write(
            source.join("hooks").join("my-hook.sh"),
            test_hook_script("my-hook", "echo current source"),
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
        fs::write(
            project.join(".claude/hooks/my-hook.sh"),
            test_hook_script("my-hook", "echo previously installed source"),
        )
        .unwrap();
        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };

        assert!(recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        ));

        let entry = lock.entries.get("my-hook").unwrap();
        assert_eq!(entry.harnesses, vec!["claude-code".to_string()]);
        assert!(entry.source_hash.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_skips_same_named_foreign_script() {
        let dir = sandbox("hook_recover_foreign");
        let source = dir.join("source");
        let project = dir.join("project");
        fs::create_dir_all(source.join("hooks")).unwrap();
        fs::write(
            source.join("hooks").join("my-hook.sh"),
            test_hook_script("my-hook", "echo source"),
        )
        .unwrap();
        fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
        fs::write(
            project.join(".claude/hooks/my-hook.sh"),
            "#!/usr/bin/env bash
echo foreign
",
        )
        .unwrap();
        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };

        let modified = recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        );

        assert!(!modified);
        assert!(!lock.entries.contains_key("my-hook"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_recovers_cursor_rule_only() {
        let dir = sandbox("hook_recover_cursor");
        let source = dir.join("source");
        let project = dir.join("project");
        fs::create_dir_all(source.join("hooks")).unwrap();
        let source_hook_path = source.join("hooks").join("cursor-hook.sh");
        fs::write(
            &source_hook_path,
            test_hook_script("cursor-hook", "echo source"),
        )
        .unwrap();
        let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
        fs::create_dir_all(project.join(".cursor").join("rules")).unwrap();
        fs::write(
            project.join(".cursor/rules/safety-cursor-hook.mdc"),
            crate::installer::cursor_hook_rule_contents(&hook),
        )
        .unwrap();
        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };

        assert!(recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        ));

        let entry = lock.entries.get("cursor-hook").unwrap();
        assert_eq!(entry.harnesses, vec!["cursor".to_string()]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_ignores_cursor_rule_for_global_scope() {
        let dir = sandbox("hook_recover_cursor_global");
        let source = dir.join("source");
        let project = dir.join("project");
        let cursor_global_rules_dir = dir.join("global-cursor").join("rules");
        fs::create_dir_all(source.join("hooks")).unwrap();
        let source_hook_path = source.join("hooks").join("cursor-hook.sh");
        fs::write(
            &source_hook_path,
            test_hook_script("cursor-hook", "echo source"),
        )
        .unwrap();
        let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
        fs::create_dir_all(&cursor_global_rules_dir).unwrap();
        fs::write(
            cursor_global_rules_dir.join("safety-cursor-hook.mdc"),
            crate::installer::cursor_hook_rule_contents(&hook),
        )
        .unwrap();
        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };
        let modified = recover_hook_lock_entries_at_with_cursor_global_rules(
            &mut lock,
            &project,
            true,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
            &cursor_global_rules_dir,
        );

        assert!(
            !modified,
            "global recovery must not record project-only Cursor hooks"
        );
        assert!(
            !lock.entries.contains_key("cursor-hook"),
            "Cursor must be absent from global hook lock recovery"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_recovers_codex_prose_fallback_only() {
        let dir = sandbox("hook_recover_codex_prose");
        let source = dir.join("source");
        let project = dir.join("project");
        fs::create_dir_all(source.join("hooks")).unwrap();
        let source_hook_path = source.join("hooks").join("prose-hook.sh");
        fs::write(
            &source_hook_path,
            test_hook_script_with_event("prose-hook", "TaskCompleted", "echo source"),
        )
        .unwrap();
        let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
        fs::create_dir_all(project.join(".codex").join("agents")).unwrap();
        fs::write(
            project.join(".codex/agents/rust.toml"),
            format!(
                "developer_instructions = '''
{}
'''
",
                crate::installer::codex_hook_safety_block(&hook)
            ),
        )
        .unwrap();
        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };

        assert!(recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        ));

        let entry = lock.entries.get("prose-hook").unwrap();
        assert_eq!(entry.harnesses, vec!["codex".to_string()]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_recovers_stale_generated_text_after_source_change() {
        let dir = sandbox("hook_recover_stale_text");
        let source = dir.join("source");
        let project = dir.join("project");
        let hooks_dir = source.join("hooks");
        fs::create_dir_all(&hooks_dir).unwrap();

        fs::write(
            hooks_dir.join("text-hook.sh"),
            test_hook_script_with_meta(
                "text-hook",
                "PreToolUse",
                "Bash",
                "current description",
                "echo current",
            ),
        )
        .unwrap();
        let old_text_hook_path = dir.join("old-text-hook.sh");
        fs::write(
            &old_text_hook_path,
            test_hook_script_with_meta(
                "text-hook",
                "PreToolUse",
                "Bash",
                "previous description",
                "echo previous",
            ),
        )
        .unwrap();
        let old_text_hook = crate::hook::Hook::from_file(&old_text_hook_path).unwrap();

        fs::write(
            hooks_dir.join("prose-hook.sh"),
            test_hook_script_with_meta(
                "prose-hook",
                "TaskCompleted",
                "Bash",
                "current description",
                "echo current",
            ),
        )
        .unwrap();
        let old_prose_hook_path = dir.join("old-prose-hook.sh");
        fs::write(
            &old_prose_hook_path,
            test_hook_script_with_meta(
                "prose-hook",
                "TaskCompleted",
                "Bash",
                "previous description",
                "echo previous",
            ),
        )
        .unwrap();
        let old_prose_hook = crate::hook::Hook::from_file(&old_prose_hook_path).unwrap();

        fs::create_dir_all(project.join(".cursor/rules")).unwrap();
        fs::write(
            project.join(".cursor/rules/safety-text-hook.mdc"),
            crate::installer::cursor_hook_rule_contents(&old_text_hook),
        )
        .unwrap();
        fs::create_dir_all(project.join(".opencode/instructions")).unwrap();
        fs::write(
            project.join(".opencode/instructions/vstack-hook-text-hook.md"),
            crate::installer::opencode_hook_instruction_contents(&old_text_hook),
        )
        .unwrap();
        fs::create_dir_all(project.join(".codex/agents")).unwrap();
        fs::write(
            project.join(".codex/agents/rust.toml"),
            format!(
                "developer_instructions = '''
{}
'''
",
                crate::installer::codex_hook_safety_block(&old_prose_hook)
            ),
        )
        .unwrap();

        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };
        assert!(recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        ));

        let text_entry = lock.entries.get("text-hook").unwrap();
        assert_eq!(
            text_entry.harnesses,
            vec!["cursor".to_string(), "opencode".to_string()]
        );
        let prose_entry = lock.entries.get("prose-hook").unwrap();
        assert_eq!(prose_entry.harnesses, vec!["codex".to_string()]);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_rejects_same_named_foreign_generated_text() {
        let dir = sandbox("hook_recover_foreign_text");
        let source = dir.join("source");
        let project = dir.join("project");
        let hooks_dir = source.join("hooks");
        fs::create_dir_all(&hooks_dir).unwrap();

        fs::write(
            hooks_dir.join("text-hook.sh"),
            test_hook_script_with_meta(
                "text-hook",
                "PreToolUse",
                "Bash",
                "source description",
                "echo source",
            ),
        )
        .unwrap();
        let foreign_text_hook_path = dir.join("foreign-text-hook.sh");
        fs::write(
            &foreign_text_hook_path,
            test_hook_script_with_meta(
                "text-hook",
                "PostToolUse",
                "Edit|Write",
                "source description",
                "echo foreign",
            ),
        )
        .unwrap();
        let foreign_text_hook = crate::hook::Hook::from_file(&foreign_text_hook_path).unwrap();

        fs::write(
            hooks_dir.join("prose-hook.sh"),
            test_hook_script_with_meta(
                "prose-hook",
                "TaskCompleted",
                "Bash",
                "source description",
                "echo source",
            ),
        )
        .unwrap();
        let foreign_prose_hook_path = dir.join("foreign-prose-hook.sh");
        fs::write(
            &foreign_prose_hook_path,
            test_hook_script_with_meta(
                "prose-hook",
                "PreToolUse",
                "Bash",
                "source description",
                "echo foreign",
            ),
        )
        .unwrap();
        let foreign_prose_hook = crate::hook::Hook::from_file(&foreign_prose_hook_path).unwrap();

        fs::create_dir_all(project.join(".cursor/rules")).unwrap();
        fs::write(
            project.join(".cursor/rules/safety-text-hook.mdc"),
            crate::installer::cursor_hook_rule_contents(&foreign_text_hook),
        )
        .unwrap();
        fs::create_dir_all(project.join(".opencode/instructions")).unwrap();
        fs::write(
            project.join(".opencode/instructions/vstack-hook-text-hook.md"),
            crate::installer::opencode_hook_instruction_contents(&foreign_text_hook),
        )
        .unwrap();
        fs::create_dir_all(project.join(".codex/agents")).unwrap();
        fs::write(
            project.join(".codex/agents/rust.toml"),
            format!(
                "developer_instructions = '''
{}
'''
",
                crate::installer::codex_hook_safety_block(&foreign_prose_hook)
            ),
        )
        .unwrap();

        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };
        assert!(!recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        ));
        assert!(lock.entries.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn recover_hook_lock_entries_codex_prose_requires_exact_header_line() {
        let dir = sandbox("hook_recover_codex_prefix");
        let source = dir.join("source");
        let project = dir.join("project");
        let hooks_dir = source.join("hooks");
        fs::create_dir_all(&hooks_dir).unwrap();
        fs::write(
            hooks_dir.join("foo.sh"),
            test_hook_script_with_event("foo", "TaskCompleted", "echo foo"),
        )
        .unwrap();
        let foo_bar_path = hooks_dir.join("foo-bar.sh");
        fs::write(
            &foo_bar_path,
            test_hook_script_with_event("foo-bar", "TaskCompleted", "echo foo-bar"),
        )
        .unwrap();
        let foo_bar_hook = crate::hook::Hook::from_file(&foo_bar_path).unwrap();

        fs::create_dir_all(project.join(".codex/agents")).unwrap();
        fs::write(
            project.join(".codex/agents/rust.toml"),
            format!(
                "developer_instructions = '''
{}
'''
",
                crate::installer::codex_hook_safety_block(&foo_bar_hook)
            ),
        )
        .unwrap();

        let mut lock = LockFile {
            version: 1,
            entries: std::collections::BTreeMap::new(),
        };
        assert!(recover_hook_lock_entries_at(
            &mut lock,
            &project,
            false,
            &source.display().to_string(),
            "2026-06-07T00:00:00Z",
        ));

        assert!(!lock.entries.contains_key("foo"));
        assert_eq!(
            lock.entries.get("foo-bar").unwrap().harnesses,
            vec!["codex".to_string()]
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn hash_dir_bytes_skips_unreadable_files_atomically() {
        // Build two trees: A has files (a, b). B has the same files plus a
        // third file (c) we'll make unreadable. Hashing B with c unreadable
        // must equal hashing A — i.e. an unreadable file must contribute
        // nothing, including no relpath bytes.
        let dir = sandbox("hash_dir_unreadable");
        let a = dir.join("a");
        let b = dir.join("b");
        fs::create_dir_all(&a).unwrap();
        fs::create_dir_all(&b).unwrap();
        fs::write(a.join("one.txt"), b"one").unwrap();
        fs::write(a.join("two.txt"), b"two").unwrap();
        fs::write(b.join("one.txt"), b"one").unwrap();
        fs::write(b.join("two.txt"), b"two").unwrap();
        let extra = b.join("three.txt");
        fs::write(&extra, b"three").unwrap();

        let hash_a = hash_dir_bytes(&a);
        // Sanity: with all files readable, hashes diverge.
        let hash_b_full = hash_dir_bytes(&b);
        assert_ne!(hash_a, hash_b_full);

        // Unreadable on Unix: chmod 000. Skip the assertion if we couldn't
        // strip read permission (e.g. running as root).
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&extra, fs::Permissions::from_mode(0o000)).unwrap();
            let readable = fs::read(&extra).is_ok();
            if !readable {
                let hash_b_partial = hash_dir_bytes(&b);
                // Restore so cleanup can run.
                let _ = fs::set_permissions(&extra, fs::Permissions::from_mode(0o644));
                assert_eq!(
                    hash_a, hash_b_partial,
                    "unreadable file must contribute neither relpath nor content bytes"
                );
            } else {
                let _ = fs::set_permissions(&extra, fs::Permissions::from_mode(0o644));
            }
        }
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn is_temporary_local_path_catches_nonexistent_temp_paths() {
        // Use the actual temp_dir() so the test works on whatever OS we run
        // on. Append a path component that we never create on disk.
        let temp = std::env::temp_dir();
        let phantom = temp.join("vstack-phantom-never-created-xyz123");
        assert!(
            !phantom.exists(),
            "precondition: phantom path must not exist"
        );

        assert!(
            is_temporary_local_path(&phantom.display().to_string()),
            "non-existent path under temp_dir must still be flagged temporary"
        );
    }

    #[test]
    fn is_temporary_local_path_handles_tmp_private_tmp_aliasing() {
        // On macOS /tmp is a symlink to /private/tmp; on Linux they are
        // distinct dirs (but generally /tmp is the temp dir). We only
        // assert the positive direction: paths under /tmp are temp.
        if std::env::temp_dir() == Path::new("/tmp")
            || std::env::temp_dir().starts_with("/private/tmp")
        {
            assert!(is_temporary_local_path("/tmp/vstack-install-foo"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn prunes_broken_generated_skill_symlinks_only() {
        use std::os::unix::fs::symlink;

        let dir = sandbox("prune_broken_skill_symlinks");
        let claude_skills = dir.join(".claude").join("skills");
        let managed_root = dir.join(".agents").join("skills");
        fs::create_dir_all(&claude_skills).unwrap();
        fs::create_dir_all(&managed_root).unwrap();

        let broken_managed = claude_skills.join("agent-browser");
        symlink("../../.agents/skills/agent-browser", &broken_managed).unwrap();

        let external_broken = claude_skills.join("external");
        symlink("../../not-vstack/skills/external", &external_broken).unwrap();

        fs::create_dir_all(managed_root.join("github")).unwrap();
        let live_managed = claude_skills.join("github");
        symlink("../../.agents/skills/github", &live_managed).unwrap();

        let modified = prune_broken_skill_symlinks_in_dirs(&[claude_skills], &[managed_root]);

        assert!(modified, "broken generated symlink should be pruned");
        assert!(
            !broken_managed.is_symlink(),
            "stale .claude/skills symlink to missing .agents/skills target must be removed"
        );
        assert!(
            external_broken.is_symlink(),
            "non-vstack broken symlinks must be left alone"
        );
        assert!(
            live_managed.is_symlink() && live_managed.exists(),
            "live generated symlinks must be preserved"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn migrates_copy_skill_lock_entry_when_existing_mirror_is_managed_symlink() {
        use std::os::unix::fs::symlink;

        let dir = sandbox("migrate_copy_skill_lock_symlink_mirror");
        let claude_skills = dir.join(".claude").join("skills");
        let managed_root = dir.join(".agents").join("skills");
        fs::create_dir_all(&claude_skills).unwrap();
        fs::create_dir_all(managed_root.join("reviewer")).unwrap();
        symlink(
            "../../.agents/skills/reviewer",
            claude_skills.join("reviewer"),
        )
        .unwrap();

        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "reviewer".into(),
            kind: ItemKind::Skill,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });

        let modified = migrate_copy_skill_lock_entries_with_symlink_mirrors(
            &mut lock,
            &[("claude-code".into(), claude_skills)],
            &[managed_root],
        );

        assert!(modified, "copy lock should migrate for managed symlink");
        let entry = lock.entries.get("reviewer").unwrap();
        assert_eq!(entry.method, InstallMethod::Symlink);
        assert!(
            !entry.source_hash.is_empty(),
            "migration must refresh source hash"
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn leaves_copy_skill_lock_entry_for_external_symlink() {
        use std::os::unix::fs::symlink;

        let dir = sandbox("migrate_copy_skill_lock_external_symlink");
        let claude_skills = dir.join(".claude").join("skills");
        let managed_root = dir.join(".agents").join("skills");
        let external_root = dir.join("external").join("skills");
        fs::create_dir_all(&claude_skills).unwrap();
        fs::create_dir_all(external_root.join("reviewer")).unwrap();
        symlink(
            "../../external/skills/reviewer",
            claude_skills.join("reviewer"),
        )
        .unwrap();

        let mut lock = LockFile::default();
        lock.add(LockEntry {
            name: "reviewer".into(),
            kind: ItemKind::Skill,
            source: "source".into(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });

        let modified = migrate_copy_skill_lock_entries_with_symlink_mirrors(
            &mut lock,
            &[("claude-code".into(), claude_skills)],
            &[managed_root],
        );

        assert!(!modified, "external symlink must not migrate lock mode");
        assert_eq!(
            lock.entries.get("reviewer").unwrap().method,
            InstallMethod::Copy
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn reconcile_recovers_pi_extensions_present_on_disk_missing_from_lock() {
        // Drive reconciliation through a sandbox PI_CODING_AGENT_DIR. We
        // populate the source index plus a fake installed package, leave
        // the lock empty, and verify reconcile re-adds the lock entry.
        let dir = sandbox("reconcile_recovers_pi");
        let pi_dir = dir.join("pi-agent");
        fs::create_dir_all(&pi_dir).unwrap();
        let pkg_root = pi_dir.join("packages").join("@vanillagreen");
        let installed_pkg = pkg_root.join("pi-foo");
        fs::create_dir_all(&installed_pkg).unwrap();
        fs::write(
            installed_pkg.join("package.json"),
            r#"{"name":"@vanillagreen/pi-foo","version":"1.0.0"}"#,
        )
        .unwrap();

        // Source repo with a matching pi-extension dir so compute_source_hash succeeds.
        let source_repo = dir.join("source-repo");
        let src_pkg = source_repo.join("pi-extensions").join("pi-foo");
        fs::create_dir_all(&src_pkg).unwrap();
        fs::write(
            src_pkg.join("package.json"),
            r#"{"name":"@vanillagreen/pi-foo","version":"1.0.0"}"#,
        )
        .unwrap();

        // Source index pointing at the source repo.
        let index_path = pi_dir.join(".vstack-source.json");
        let index_json = serde_json::json!({
            "@vanillagreen/pi-foo": {
                "sourceRepo": source_repo.display().to_string(),
                "sourcePath": src_pkg.display().to_string(),
                "sourceVersion": "1.0.0"
            }
        });
        fs::write(&index_path, index_json.to_string()).unwrap();

        // Redirect global pi dir to the sandbox via the shared lock so we
        // don't race other PI_CODING_AGENT_DIR-mutating tests.
        let (modified, recovered) = crate::test_util::with_pi_dir(&pi_dir, || {
            let mut lock = LockFile {
                version: 1,
                ..Default::default()
            };
            let modified =
                reconcile_lock_with_disk(&mut lock, true, &source_repo.display().to_string());
            let recovered = lock.entries.get("@vanillagreen/pi-foo").cloned();
            (modified, recovered)
        });

        assert!(modified, "reconcile must report modification");
        let recovered = recovered.expect("pi extension lock entry must be re-added");
        assert_eq!(recovered.kind, ItemKind::PiExtension);
        assert_eq!(recovered.source, source_repo.display().to_string());
        assert!(
            !recovered.source_hash.is_empty(),
            "recovered entry must carry a source hash"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
