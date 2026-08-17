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

    /// Plural of [`label_short`], for grouped listings.
    pub fn label_plural(self) -> &'static str {
        match self {
            ItemKind::Agent => "agents",
            ItemKind::Skill => "skills",
            ItemKind::Hook => "hooks",
            ItemKind::PiExtension => "pi-packages",
            ItemKind::Extra => "extras",
        }
    }

    /// The `vstack add` name filter that installs this kind, or None for a
    /// kind that only installs through the TUI (extras).
    pub fn add_filter_flag(self) -> Option<&'static str> {
        match self {
            ItemKind::Agent => Some("--agent"),
            ItemKind::Skill => Some("--skill"),
            ItemKind::Hook => Some("--hook"),
            ItemKind::PiExtension => Some("--pi-extension"),
            ItemKind::Extra => None,
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
    /// Per settings key, the FNV-1a hash of the comment block last seeded
    /// into `vstack.settings.toml`. A key's comment is refreshed from the
    /// skill template only while its current text still hashes to this
    /// value — a comment the user edited stops matching and is never
    /// rewritten. Project-scope locks only.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub settings_seeds: BTreeMap<String, String>,
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

/// Serialize `value` as pretty JSON terminated by exactly one newline.
/// vstack's JSON artifacts are POSIX text files and some are tracked by
/// consuming repos (`.vstack-lock.json`), so the terminator keeps every
/// rewrite from adding a `\ No newline at end of file` line to their diffs.
pub fn to_json_pretty(value: &impl Serialize) -> Result<String> {
    let mut out = serde_json::to_string_pretty(value)?;
    if !out.ends_with('\n') {
        out.push('\n');
    }
    Ok(out)
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
        let content = to_json_pretty(self)?;
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
    /// preserved unconditionally — they're not paths to check. A per-project
    /// choice is dropped when either side is a dead path: its source, or the
    /// project root it was recorded for. Returns the number of entries removed.
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
            .retain(|project, source| !is_dead_local_path(project) && !is_dead_local_path(source));
        before - self.entries.len() + before_project - self.project_current.len()
    }

    pub fn save(&self, path: &Path) -> Result<()> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let content = to_json_pretty(self)?;
        std::fs::write(path, content)?;
        Ok(())
    }

    /// Drop `entries` that resolve to `project_root` itself while that root
    /// provably lacks vstack source content — consumer projects recorded as
    /// their own source by project-local installs (vstack#1024). Command
    /// paths that know the project root call this before persisting
    /// (vstack#1038). Scoped to the current project on purpose (#1047
    /// review): entries elsewhere on disk are never judged, because a
    /// registered minimal source (e.g. a skills-only checkout added by
    /// explicit path) fails the two-dir content shape without being stale.
    /// Returns the number removed.
    pub fn prune_project_self_non_source(&mut self, project_root: &Path) -> usize {
        let before = self.entries.len();
        self.entries
            .retain(|entry| !is_project_self_non_source(entry, project_root));
        before - self.entries.len()
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

/// True iff `entry` is a local path resolving to `project_root` itself while
/// that root provably lacks vstack source content — the content-based check
/// source resolution uses (vstack#1037). Entries elsewhere on disk are never
/// judged (#1047 review): a minimal source layout is legitimate, and a
/// missing path proves nothing about its content.
pub(crate) fn is_project_self_non_source(entry: &str, project_root: &Path) -> bool {
    let Some(path) = expanded_local_path(entry) else {
        return false;
    };
    path.exists()
        && crate::resolve::same_path(&path, project_root)
        && !crate::resolve::has_vstack_source_content(project_root)
}

/// The local-path shapes a registry entry or project key can take: absolute
/// for the running platform (`/…` on Unix; `C:\…` and `\\server\share\…` on
/// Windows), `~`-tilde, or relative starting with `.`. Remote shorthand
/// (`owner/repo`) and URLs are never paths.
fn expanded_local_path(entry: &str) -> Option<PathBuf> {
    let looks_like_path = Path::new(entry).is_absolute()
        || entry.starts_with('/')
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

pub(crate) fn fnv1a(data: &[u8]) -> u64 {
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

/// Extract the shared `all`/`"*"` values from the instruction tables that
/// apply to one item kind, canonically serialized. Scoped to the named tables
/// on purpose: a shared agent-instruction edit must not stale skill installs
/// (and vice versa) — table-agnostic key lookup would cross-invalidate.
fn extract_shared_instruction_sections(path: &Path, tables: &[&str]) -> Vec<u8> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(toml::Value::Table(root)) = content.parse::<toml::Value>() else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for table_name in tables {
        let Some(toml::Value::Table(table)) = root.get(*table_name) else {
            continue;
        };
        // Same precedence as shared_instruction_entry: `all` shadows `"*"`,
        // so only the effective entry feeds the hash — editing a shadowed
        // alias changes no rendered output and must not stale installs.
        for key in [
            crate::project_config::SHARED_INSTRUCTIONS_KEY,
            crate::project_config::SHARED_INSTRUCTIONS_KEY_ALIAS,
        ] {
            if let Some(value) = table.get(key) {
                result.extend_from_slice(format!("{table_name}.{key} = {value}\n").as_bytes());
                break;
            }
        }
    }
    result
}

/// The instruction tables whose shared `all`/`"*"` entries render into items
/// of each kind, including the legacy serde aliases ProjectConfig accepts
/// (`agent-guidance`, `agent-instructions`).
const AGENT_SHARED_TABLES: &[&str] = &[
    "agent-launch-instructions",
    "agent-guidance",
    "agent-additional-instructions",
    "agent-instructions",
];
const SKILL_SHARED_TABLES: &[&str] = &["skill-instructions"];

/// Extract the values for a given key from a TOML file, wherever the key
/// appears: top level or inside any (nested) table. Values are canonically
/// re-serialized so the hash tracks content rather than source formatting —
/// the real TOML parser handles multiline bodies and escaped quotes that a
/// line scanner cannot. Returns empty bytes if the file is missing,
/// unparsable, or the key absent.
fn extract_toml_section_for(path: &Path, name: &str) -> Vec<u8> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(toml::Value::Table(table)) = content.parse::<toml::Value>() else {
        return Vec::new();
    };
    let mut result = Vec::new();
    collect_key_values("", &table, name, &mut result);
    result
}

fn collect_key_values(prefix: &str, table: &toml::value::Table, name: &str, out: &mut Vec<u8>) {
    for (key, value) in table {
        if key == name {
            out.extend_from_slice(format!("{prefix}{key} = {value}\n").as_bytes());
        }
        if let toml::Value::Table(nested) = value {
            collect_key_values(&format!("{prefix}{key}."), nested, name, out);
        }
    }
}

mod remote_cache;

/// The remote-cache surface stays reachable as `config::…`, exactly as it was
/// before the subsystem moved into its own module.
pub use remote_cache::*;

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
        let path = Path::new(url);
        let has_windows_drive = url.as_bytes().get(1) == Some(&b':');
        if path.is_absolute()
            || url.starts_with("./")
            || url.starts_with("../")
            || url.starts_with(".\\")
            || url.starts_with("..\\")
            || url.contains('\\')
            || has_windows_drive
        {
            return None;
        }
        let bare = url.strip_suffix(".git").unwrap_or(url);
        let mut parts = bare.split('/');
        if let (Some(owner), Some(repo), None) = (parts.next(), parts.next(), parts.next()) {
            return github_slug_from(owner, repo);
        }
        return None;
    }

    let after = if let Some(after) = url.strip_prefix("git@github.com:") {
        after
    } else if let Some(after_scheme) = url.strip_prefix("https://") {
        let (authority, path) = after_scheme.split_once('/')?;
        let host = authority.rsplit('@').next()?;
        if !host.eq_ignore_ascii_case("github.com") {
            return None;
        }
        path
    } else {
        url.strip_prefix("ssh://git@github.com/")?
    };
    let after = after
        .trim_end_matches('/')
        .strip_suffix(".git")
        .unwrap_or(after);
    let mut parts = after.split('/');
    let owner = parts.next()?;
    let repo = parts.next()?;
    if parts.next().is_some() {
        return None;
    }
    github_slug_from(owner, repo)
}

/// The one place a slug is minted, so every caller gets a name GitHub could
/// actually have.
///
/// The charset is the gate, not a tidy-up. A slug is pasted straight into
/// `https://github.com/{slug}.git` for the bare `owner/repo` shorthand, which
/// is not URL-shaped and so never reaches the credential refusal: without
/// this, `owner/repo?access_token=secret.git` handed the token to `git clone`
/// and to every diagnostic the URL appears in. Reserved URL characters — `?`,
/// `#`, `@`, `:`, `%` — are therefore not owner or repository name characters
/// here, and `.`/`..` are not names at all.
fn github_slug_from(owner: &str, repo: &str) -> Option<String> {
    fn is_name(part: &str) -> bool {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'))
    }
    (is_name(owner) && is_name(repo)).then(|| {
        format!(
            "{}/{}",
            owner.to_ascii_lowercase(),
            repo.to_ascii_lowercase()
        )
    })
}

pub fn github_slug_eq(left: &str, right: &str) -> bool {
    parse_github_slug(left)
        .zip(parse_github_slug(right))
        .is_some_and(|(left, right)| left == right)
}

fn source_repo_from_git_origin(source_root: &Path) -> Option<String> {
    // The answer must belong to THIS root: a directory that merely sits inside
    // a repository is not that repository, and git discovery walks up out of
    // one that is not — a half-written cache entry inside a checkout would
    // otherwise be stamped into the lock with the ENCLOSING repository's
    // identity, and `vstack report` would file issues against it.
    let toplevel = crate::refresh_sources::hardened_git_command(source_root)
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()?;
    if !toplevel.status.success() {
        return None;
    }
    let toplevel = PathBuf::from(String::from_utf8_lossy(&toplevel.stdout).trim());
    let same = std::fs::canonicalize(&toplevel)
        .ok()
        .zip(std::fs::canonicalize(source_root).ok())
        .is_some_and(|(toplevel, root)| toplevel == root);
    if !same {
        return None;
    }
    let output = crate::refresh_sources::hardened_git_command(source_root)
        .args(["remote", "get-url", "origin"])
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
    match resolve_source_path(&entry.source) {
        Some(root) => compute_source_hash_in(entry, &root),
        None => String::new(),
    }
}

/// [`compute_source_hash`] against an already-resolved source root, for a
/// caller that resolved it itself — `check` and `verify` resolve once to
/// report the cause when there is no root, and would otherwise resolve a
/// second time here.
pub fn compute_source_hash_in(entry: &LockEntry, source_root: &Path) -> String {
    let source_root = source_root.to_path_buf();
    let proj_root = project_root();

    let mut state = FNV_OFFSET;

    match entry.kind {
        ItemKind::Skill => {
            let dir = crate::catalog::find_item_path(&source_root, entry.kind, &entry.name);
            if let Some(dir) = dir.as_deref()
                && dir.exists()
            {
                state = fnv1a_chain(state, &hash_dir_bytes(dir).to_le_bytes());
            }
            // Hash this skill's section plus the shared `all`/`*` entries of
            // the skill instruction table — a shared-key edit changes every
            // rendered skill, so it must stale every skill install.
            // project_config_path honors the vstack-local.toml redirect for
            // source-catalog projects.
            let project_config = crate::project_config::project_config_path(&proj_root);
            let section = extract_toml_section_for(&project_config, &entry.name);
            if !section.is_empty() {
                state = fnv1a_chain(state, &section);
            }
            let shared = extract_shared_instruction_sections(&project_config, SKILL_SHARED_TABLES);
            if !shared.is_empty() {
                state = fnv1a_chain(state, &shared);
            }
        }
        ItemKind::Agent => {
            let file = crate::catalog::find_item_path(&source_root, entry.kind, &entry.name);
            if let Some(file) = file.as_deref()
                && file.exists()
            {
                state = fnv1a_chain(state, &hash_file_bytes(file).to_le_bytes());
            }
            // Hash this agent's sections plus the shared `all`/`*` entries of
            // the agent instruction tables from both configs — a shared-key
            // edit changes every rendered agent, so it must stale every agent
            // install. project_config_path honors the vstack-local.toml
            // redirect for source-catalog projects.
            let source_config = source_root.join("vstack.toml");
            for config_path in [
                &source_config,
                &crate::project_config::project_config_path(&proj_root),
            ] {
                let section = extract_toml_section_for(config_path, &entry.name);
                if !section.is_empty() {
                    state = fnv1a_chain(state, &section);
                }
                let shared = extract_shared_instruction_sections(config_path, AGENT_SHARED_TABLES);
                if !shared.is_empty() {
                    state = fnv1a_chain(state, &shared);
                }
            }
            // The failure-reporting reference renders into every agent (and
            // is installed alongside them); a release that changes only the
            // canonical document must stale agent installs so refresh rewrites
            // the on-disk copy.
            state = fnv1a_chain(state, crate::agent::FAILURE_REPORTING_DOC.as_bytes());
        }
        ItemKind::Hook => {
            let file = crate::catalog::find_item_path(&source_root, entry.kind, &entry.name);
            if let Some(file) = file.as_deref()
                && file.exists()
            {
                state = fnv1a_chain(state, &hash_file_bytes(file).to_le_bytes());
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
            if let Some(dir) = crate::catalog::find_item_path(&source_root, entry.kind, &entry.name)
                .or_else(|| resolve_pi_extension_dir(&source_root, &entry.name))
            {
                state = fnv1a_chain(state, &hash_dir_bytes(&dir).to_le_bytes());
            }
        }
        ItemKind::Extra => {
            let dir = crate::catalog::find_item_path(&source_root, entry.kind, &entry.name);
            if let Some(dir) = dir.as_deref()
                && dir.exists()
            {
                state = fnv1a_chain(state, &hash_dir_bytes(dir).to_le_bytes());
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
    // An unresolved source hashes to nothing, which reads as changed — that is
    // what puts a vanished-source entry in the TUI's Updates list, where
    // picking it reports the source as gone.
    compute_source_hash(entry) != entry.source_hash
}

/// [`is_source_changed`] against an already-resolved source root.
pub fn is_source_changed_in(entry: &LockEntry, source_root: &Path) -> bool {
    if entry.source_hash.is_empty() {
        return false; // No hash stored — assume fresh (legacy lock)
    }
    compute_source_hash_in(entry, source_root) != entry.source_hash
}

/// Discovered item on disk that was installed by vstack.
#[derive(Debug)]
pub struct DiskItem {
    pub name: String,
    pub kind: ItemKind,
    /// For a skill admitted through an anchored root's gate: the harnesses
    /// whose artifacts resolve to that canonical. Recovery must scope the
    /// entry to exactly these — a same-named non-resolving harness dir is an
    /// independent copy-mode install, and recording it under the recovered
    /// Symlink entry would let the next refresh replace the copy.
    pub anchored_harnesses: Option<Vec<String>>,
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

    // Canonical skill location: .agents/skills/<name>/. Project scope also
    // consults checkout-anchored roots so a copy anchored in the main
    // checkout by a worktree-run install (VST-195) is still discovered — but
    // a copy there belongs to this project's view only when a harness that
    // shares into that checkout actually references it, so anchored roots
    // carry the sharing harnesses as a gate.
    let canonical_skills: Vec<(PathBuf, Option<crate::installer::AnchorSharing>)> = if global {
        vec![
            (global_state_dir().join("skills"), None),
            (codex_home_dir().join("skills"), None),
        ]
    } else {
        // The project-spelled canonical root can PHYSICALLY live in another
        // checkout (fully shared .agents): scanning it ungated would treat
        // the owner's canonicals as local. Gate it by reference like any
        // anchored root in that case.
        let own_skills = project_root().join(".agents").join("skills");
        let own_skills_shared = own_skills
            .canonicalize()
            .ok()
            .zip(project_root().canonicalize().ok())
            .is_some_and(|(skills, root)| !skills.starts_with(&root));
        let local_gate: Option<crate::installer::AnchorSharing> = if own_skills_shared {
            Some(
                crate::harness::Harness::ALL
                    .iter()
                    .map(|harness| (*harness, crate::installer::AnchorEvidence::SharedDir))
                    .collect(),
            )
        } else {
            None
        };
        let mut roots = vec![(own_skills, local_gate)];
        for (root, sharing) in
            crate::installer::anchored_canonical_skill_roots(crate::harness::Harness::ALL)
        {
            roots.push((root, Some(sharing)));
        }
        roots
    };

    for (skills_dir, gate) in canonical_skills {
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
            // Local roots require the managed marker. Anchored roots admit
            // an UNMARKED canonical too — a foreign worktree's removal
            // deliberately clears the marker while the owning checkout's
            // references survive, and those references (checked below) are
            // the recovery evidence; requiring the marker there made
            // `vstack check` report a still-installed skill as missing.
            if gate.is_none() && !path.join(".vstack-refreshed").exists() {
                continue;
            }
            // An UNMARKED anchored canonical is admitted only when it also
            // LOOKS like a vstack-managed install: a REAL directory with
            // SKILL.md. Reference evidence alone would adopt a manually
            // maintained same-named directory, and a SYMLINK canonical is
            // the owner's project-skills-dir wiring (every project-owned
            // skill has SKILL.md too) — neither is vstack's to claim.
            if gate.is_some() && !path.join(".vstack-refreshed").exists() {
                let is_symlink = std::fs::symlink_metadata(&path)
                    .is_ok_and(|meta| meta.file_type().is_symlink());
                if is_symlink || !path.join("SKILL.md").exists() {
                    continue;
                }
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            let anchored_harnesses = match &gate {
                Some(sharing) => {
                    // A reference must RESOLVE to this canonical dir. A
                    // same-named copy-mode dir in a harness dir is that
                    // harness's own install, not a reference — recovering
                    // through it would re-type the skill as symlink-mode and
                    // let the next refresh replace the copy. Only the
                    // resolving harnesses are recorded, so recovery cannot
                    // attach that independent install to the anchored entry.
                    // Only SYMLINK artifacts are references: a direct
                    // Codex/Pi artifact in a shared layout IS the canonical
                    // dir itself, and counting that self-identity would let
                    // a lockless worktree recover every main-checkout
                    // canonical as its own install.
                    let referencing: Vec<String> = match path.canonicalize() {
                        Ok(canonical) => sharing
                            .iter()
                            .filter(|(harness, _)| {
                                let artifact = harness.skills_dir(false).join(name);
                                std::fs::symlink_metadata(&artifact)
                                    .is_ok_and(|meta| meta.file_type().is_symlink())
                                    && artifact
                                        .canonicalize()
                                        .is_ok_and(|resolved| resolved == canonical)
                            })
                            .map(|(harness, _)| harness.id().to_string())
                            .collect(),
                        Err(_) => Vec::new(),
                    };
                    if referencing.is_empty() {
                        continue;
                    }
                    Some(referencing)
                }
                None => {
                    // Child-level anchor in the ungated local root: a real
                    // `.agents/skills` whose `<name>` entry is a symlink into
                    // another checkout (partial sharing). This root scans
                    // FIRST, so an unscoped entry here would win `seen` and
                    // recovery would claim every same-named harness artifact
                    // — retyping an independent copy-mode install as
                    // Symlink. Scope it to the resolving harnesses, exactly
                    // like root-level anchors.
                    let is_link = std::fs::symlink_metadata(&path)
                        .is_ok_and(|meta| meta.file_type().is_symlink());
                    if is_link {
                        match path.canonicalize() {
                            Ok(canonical) => {
                                let referencing: Vec<String> = crate::harness::Harness::ALL
                                    .iter()
                                    .filter(|harness| {
                                        harness
                                            .skills_dir(false)
                                            .join(name)
                                            .canonicalize()
                                            .is_ok_and(|resolved| resolved == canonical)
                                    })
                                    .map(|harness| harness.id().to_string())
                                    .collect();
                                if referencing.is_empty() {
                                    continue;
                                }
                                Some(referencing)
                            }
                            Err(_) => continue,
                        }
                    } else {
                        // Plain LOCAL canonical: when a same-named harness
                        // artifact resolves somewhere ELSE (an independent
                        // install in another checkout), an unscoped entry
                        // would let recovery claim it. Scope to the
                        // harnesses actually attached here in that case —
                        // symlink artifacts resolving to this canonical AND
                        // direct-canonical harnesses (Codex/Pi, whose
                        // artifact IS this directory). No locally attached
                        // harness at all means the foreign install owns
                        // every artifact: skip rather than mint a
                        // zero-harness entry. Without a foreign-resolving
                        // artifact, keep the legacy full detection.
                        let local_canonical = path.canonicalize().ok();
                        let mut resolving: Vec<String> = Vec::new();
                        let mut foreign_resolving = false;
                        for harness in crate::harness::Harness::ALL.iter() {
                            let artifact = harness.skills_dir(false).join(name);
                            let Ok(meta) = std::fs::symlink_metadata(&artifact) else {
                                continue;
                            };
                            match (artifact.canonicalize().ok(), &local_canonical) {
                                (Some(resolved), Some(local)) if resolved == *local => {
                                    resolving.push(harness.id().to_string());
                                }
                                // A symlink resolving elsewhere OR a real
                                // copy-mode directory at a different
                                // physical place — both are independent
                                // installs the recovered entry must not
                                // claim.
                                (Some(_), _)
                                    if meta.file_type().is_symlink()
                                        || meta.file_type().is_dir() =>
                                {
                                    foreign_resolving = true;
                                }
                                _ => {}
                            }
                        }
                        if foreign_resolving {
                            if resolving.is_empty() {
                                continue;
                            }
                            Some(resolving)
                        } else {
                            None
                        }
                    }
                }
            };
            // A skill can hold canonicals in MORE than one root (split
            // layout: Codex/Pi local, Claude anchored in main): merge
            // harness scopes across roots instead of first-root-wins. An
            // unscoped (None) side means full legacy detection and absorbs
            // any scoped one.
            if let Some(existing) = items
                .iter_mut()
                .find(|item: &&mut DiskItem| item.name == name && item.kind == ItemKind::Skill)
            {
                match (&mut existing.anchored_harnesses, anchored_harnesses) {
                    (Some(current), Some(mut incoming)) => {
                        for harness_id in incoming.drain(..) {
                            if !current.contains(&harness_id) {
                                current.push(harness_id);
                            }
                        }
                    }
                    (current @ Some(_), None) => *current = None,
                    (None, _) => {}
                }
            } else {
                items.push(DiskItem {
                    name: name.to_string(),
                    kind: ItemKind::Skill,
                    anchored_harnesses,
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

    let Ok(source_hooks) = crate::catalog::discover_hooks(&source_root) else {
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

pub(crate) fn generated_safety_action_line(hook: &crate::hook::Hook) -> Option<String> {
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

    // The prose fallback's presence is answered beside the install that
    // writes it, so the two can never read different bytes.
    crate::installer::codex_hook_prose(&root, hook).carried()
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

pub(crate) fn normalize_path_lexical(path: &Path) -> PathBuf {
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
    let mut dirs = harness_skill_dirs(global);
    let mut roots = managed_skill_roots(global);
    if !global {
        // Also sweep the harness dirs of same-repo checkouts that shared
        // harness dirs anchor into: a link dangling in a main-side dir the
        // worktree does NOT share is invisible to the local walk, and their
        // canonical roots must count as managed targets.
        let project_root = project_root();
        for (anchored_root, _) in
            crate::installer::anchored_canonical_skill_roots(crate::harness::Harness::ALL)
        {
            let Some(checkout_root) = anchored_root.parent().and_then(Path::parent) else {
                continue;
            };
            for harness in crate::harness::Harness::ALL {
                if let Ok(rel) = harness.skills_dir(false).strip_prefix(&project_root) {
                    let dir = checkout_root.join(rel);
                    if !dirs.contains(&dir) {
                        dirs.push(dir);
                    }
                }
            }
            if !roots.contains(&anchored_root) {
                roots.push(anchored_root);
            }
        }
    }
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
                // A resolvable recorded source is authoritative even when its
                // current Git origin is absent: synchronize stale identity to
                // the observed value, including None. If the source is
                // unavailable, retain the last durable identity until a later
                // refresh can observe it again.
                if let Some(entry_source_root) = resolve_source_path(&entry.source) {
                    let entry_source_repo = source_repo_from_git_origin(&entry_source_root);
                    if entry.source_repo != entry_source_repo {
                        entry.source_repo = entry_source_repo;
                        modified = true;
                    }
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
    for item in &disk_skills {
        if !lock.entries.contains_key(&item.name) {
            // Determine which harnesses have this skill by checking dirs.
            // An anchored item carries the harnesses that resolve to its
            // canonical; a same-named artifact for any OTHER harness is an
            // independent install this entry must not claim.
            let harnesses = match &item.anchored_harnesses {
                Some(referencing) => referencing.clone(),
                None => {
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
                    harnesses
                }
            };
            let mut entry = LockEntry {
                name: item.name.clone(),
                kind: item.kind,
                source: source.to_string(),
                // A refresh marker proves vstack manages this installed skill,
                // but not which registry supplied it. In a multi-source project
                // the single reconciliation hint is insufficient attribution.
                source_repo: None,
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
    let stale_skills: Vec<(String, Vec<String>)> = lock
        .entries
        .iter()
        .filter(|(_, e)| e.kind == ItemKind::Skill && !disk_names.contains(e.name.as_str()))
        .map(|(name, e)| (name.clone(), e.harnesses.clone()))
        .collect();
    if !stale_skills.is_empty() {
        // Verify the canonical dir is actually gone (not just missing the
        // marker) in every root a copy may live in — anchored roots count
        // for an entry only when one of ITS harnesses shares into them.
        let anchored = if global {
            Vec::new()
        } else {
            crate::installer::anchored_canonical_skill_roots(crate::harness::Harness::ALL)
        };
        let own_root = if global {
            global_state_dir().join("skills")
        } else {
            project_root().join(".agents").join("skills")
        };
        // Invariant across the loop — resolve once, not per stale entry.
        let own_root_is_local = global
            || own_root
                .canonicalize()
                .ok()
                .zip(std::fs::canonicalize(project_root()).ok())
                .is_none_or(|(root, project)| root.starts_with(&project));
        for (name, entry_harnesses) in stale_skills {
            // Entry ids may use supported aliases ("claude" for claude-code);
            // normalize through the same resolution the rest of the CLI uses.
            let entry_harnesses: Vec<crate::harness::Harness> = entry_harnesses
                .iter()
                .filter_map(|id| crate::harness::Harness::from_id(id))
                .collect();
            // A fully shared `.agents` makes own_root resolve into the
            // OTHER checkout — its contents are anchored evidence (gated
            // per-harness/per-name below), not unconditional local proof:
            // counting them here would keep any stale entry alive merely
            // because the main checkout has a same-named canonical.
            let exists = (own_root_is_local && own_root.join(&name).exists())
                || anchored.iter().any(|(root, sharing)| {
                    // Child-link evidence is per-skill: an anchored root
                    // keeps an entry alive only when it is evidenced for
                    // THIS name, not by an unrelated skill's child link.
                    sharing.iter().any(|(harness, evidence)| {
                        entry_harnesses.contains(harness) && evidence.covers(&name)
                    }) && root.join(&name).exists()
                });
            if !exists {
                eprintln!("  Removed stale lock entry (files missing): {name}");
                lock.remove(&name);
                modified = true;
            }
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
mod tests;
