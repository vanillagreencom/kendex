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
    dirs::home_dir().unwrap_or_else(|| PathBuf::from("~"))
}

pub fn user_config_dir() -> PathBuf {
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
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| user_home_dir().join(".codex"))
}

/// Global Pi config directory.
///
/// Honors `PI_CODING_AGENT_DIR` so tests can redirect to a sandbox dir
/// without touching the real `~/.pi/agent`.
pub fn pi_global_dir() -> PathBuf {
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

/// Compute a content hash for a single file.
fn hash_file_bytes(path: &Path) -> u64 {
    match std::fs::read(path) {
        Ok(content) => fnv1a(&content),
        Err(_) => 0,
    }
}

/// Compute a content hash for a directory (all files, sorted by relative path).
fn hash_dir_bytes(dir: &Path) -> u64 {
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
    let p = Path::new(source);
    if p.is_absolute() && p.is_dir() {
        return Some(p.to_path_buf());
    }
    // Check cached repo (owner/repo → ~/.vstack/cache/owner_repo)
    if source.contains('/') && !source.starts_with('.') && !source.starts_with('/') {
        let cache_key = source.replace('/', "_");
        let cache_dir = global_base_dir()
            .join(".vstack")
            .join("cache")
            .join(&cache_key);
        if cache_dir.is_dir() {
            return Some(cache_dir);
        }
    }
    // "." or relative — walk up from CWD to find vstack source
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if crate::resolve::is_vstack_source(&dir) {
            return Some(dir);
        }
        if !dir.pop() {
            break;
        }
    }
    None
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

/// Scan the canonical skill directory and harness agent/hook directories
/// for items installed by vstack. Skills are identified by the `.vstack-refreshed`
/// marker. Agents/hooks are identified by presence in harness directories that
/// vstack manages (we can only reliably detect these via the lock, so this
/// function focuses on skills).
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

/// Reconcile the lock file with what's actually on disk.
///
/// - Items on disk (with `.vstack-refreshed` marker) but missing from lock are
///   re-added.
/// - Items in lock but missing from disk are removed from lock.
/// - Returns true if the lock was modified.
pub fn reconcile_lock_with_disk(lock: &mut LockFile, global: bool, source: &str) -> bool {
    let mut modified = false;

    // Re-add skills found on disk but missing from lock
    let disk_skills = scan_installed_skills_on_disk(global);
    let now = now_iso();
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
            let mut entry = LockEntry {
                name: pkg_name.clone(),
                kind: ItemKind::PiExtension,
                source: entry_source,
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
