use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

/// The one spelling of the app's directory segment under config/cache/data.
const APP_DIR: &str = "kendex";
/// Where those directories lived before the product rename — read only by
/// the first-launch move ([`crate::rename::migrate_global_dirs`]).
const LEGACY_APP_DIR: &str = "vstack2";

/// Process env vars that relocate harness roots.
const HARNESS_VARS: [&str; 7] = [
    "CODEX_HOME",
    "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_DIR",
    "PI_CODING_AGENT_DIR",
    // Relocates Copilot's whole config root (matrix §3, §R4).
    "COPILOT_HOME",
    // Moves the Gemini settings layer that outranks project scope, which is
    // the only way to see it anywhere but its machine-wide path (matrix §R2).
    "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
    // Rebases `owner/repo` source shorthands onto another git host —
    // release smokes and tests point it at a file:// fixture tree.
    "KENDEX_GIT_BASE",
];

/// Every filesystem root the app reads or writes flows through here so tests
/// can point the whole engine at a fixture tree instead of the real machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Env {
    pub home: PathBuf,
    config_dir: PathBuf,
    cache_dir: PathBuf,
    data_dir: PathBuf,
    vars: BTreeMap<String, String>,
}

impl Env {
    pub fn detect() -> Result<Self> {
        let vars = HARNESS_VARS
            .iter()
            .filter_map(|k| std::env::var(k).ok().map(|v| ((*k).to_owned(), v)))
            .collect();
        Ok(Env {
            home: dirs::home_dir().ok_or(CoreError::NoHomeDir)?,
            config_dir: dirs::config_dir().ok_or(CoreError::NoHomeDir)?,
            cache_dir: dirs::cache_dir().ok_or(CoreError::NoHomeDir)?,
            data_dir: dirs::data_dir().ok_or(CoreError::NoHomeDir)?,
            vars,
        })
    }

    pub fn var(&self, key: &str) -> Option<&str> {
        self.vars.get(key).map(String::as_str)
    }

    pub fn with_var(mut self, key: &str, value: &str) -> Self {
        self.vars.insert(key.to_owned(), value.to_owned());
        self
    }

    /// Fixture environment shaped like the given OS, rooted under `home`.
    pub fn fake(home: impl Into<PathBuf>, os: FakeOs) -> Self {
        let home: PathBuf = home.into();
        let (config, cache, data) = match os {
            FakeOs::Linux => (
                home.join(".config"),
                home.join(".cache"),
                home.join(".local/share"),
            ),
            FakeOs::Mac => (
                home.join("Library/Application Support"),
                home.join("Library/Caches"),
                home.join("Library/Application Support"),
            ),
            FakeOs::Windows => (
                home.join("AppData/Roaming"),
                home.join("AppData/Local"),
                home.join("AppData/Roaming"),
            ),
        };
        Env {
            home,
            config_dir: config,
            cache_dir: cache,
            data_dir: data,
            vars: BTreeMap::new(),
        }
    }

    /// The platform config root itself — v1 kept its `vstack` state
    /// directly under it, resolved the same way (`dirs::config_dir()`).
    pub fn platform_config_dir(&self) -> &Path {
        &self.config_dir
    }

    fn app_config_dir(&self) -> PathBuf {
        self.config_dir.join(APP_DIR)
    }

    /// `(old, new)` per base directory, for the one-shot move off the old
    /// product name. Order matters: data first, so the scope-lock dir the
    /// move itself runs under is settled before anything else migrates.
    pub(crate) fn app_dir_pairs(&self) -> [(PathBuf, PathBuf); 3] {
        [
            (
                self.data_dir.join(LEGACY_APP_DIR),
                self.data_dir.join(APP_DIR),
            ),
            (
                self.config_dir.join(LEGACY_APP_DIR),
                self.config_dir.join(APP_DIR),
            ),
            (
                self.cache_dir.join(LEGACY_APP_DIR),
                self.cache_dir.join(APP_DIR),
            ),
        ]
    }

    /// The pre-rename spelling of a path under one of the app dirs — what a
    /// symlink written before the first-launch move still records as its
    /// target. Purely lexical: by the time a link is compared against it,
    /// the move has already emptied the old spelling, so nothing there
    /// resolves. `None` for a path outside the app dirs.
    pub fn legacy_app_path(&self, path: &Path) -> Option<PathBuf> {
        self.app_dir_pairs().iter().find_map(|(old, new)| {
            let rest = path.strip_prefix(new).ok()?;
            // Joining an empty rest would leave a trailing separator, which
            // compares unequal to the bare directory path.
            Some(match rest.as_os_str().is_empty() {
                true => old.clone(),
                false => old.join(rest),
            })
        })
    }

    pub fn settings_file(&self) -> PathBuf {
        self.app_config_dir().join("settings.toml")
    }

    pub fn global_manifest_file(&self) -> PathBuf {
        self.app_config_dir().join(crate::rename::MANIFEST_FILE)
    }

    /// Where the global manifest sat before the rename — same directory,
    /// old file name. The dir move keeps the file's own name, so a migrated
    /// machine holds `vstack.toml` here until its rename op runs.
    pub fn legacy_global_manifest_file(&self) -> PathBuf {
        self.app_config_dir()
            .join(crate::rename::LEGACY_MANIFEST_FILE)
    }

    pub fn global_lock_file(&self) -> PathBuf {
        self.app_config_dir().join("lock.json")
    }

    pub fn source_cache_dir(&self) -> PathBuf {
        self.cache_dir.join(APP_DIR).join("sources")
    }

    /// The community directory's cached index — derived, rebuildable, and
    /// the only thing served when the network is away.
    pub fn registry_cache_dir(&self) -> PathBuf {
        self.cache_dir.join(APP_DIR).join("registry")
    }

    pub fn trash_dir(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("trash")
    }

    pub fn journal_dir(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("journal")
    }

    pub fn scope_locks_dir(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("locks")
    }

    /// Per-scope drift snapshots — derived, machine-local, rebuildable. The
    /// session-start check reads these instead of doing the deep work.
    pub fn drift_dir(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("drift")
    }

    pub fn global_local_source_dir(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("local-source")
    }

    /// Rendered canonical trees for global-scope skills — the stable target
    /// native dirs link to (never the source cache, which refresh resets).
    pub fn rendered_skills_dir(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("rendered/skills")
    }

    /// Home of a per-tool skill variant that diverged from the shared
    /// rendering. A sibling of `rendered/skills`, keyed by harness, so a
    /// skill name can never collide with a variant directory.
    pub fn rendered_skill_variants_dir(&self, harness: &str) -> PathBuf {
        self.data_dir
            .join(APP_DIR)
            .join("rendered/variants")
            .join(harness)
    }

    pub fn project_manifest_file(project_root: &Path) -> PathBuf {
        project_root.join(crate::rename::MANIFEST_FILE)
    }

    pub fn project_lock_file(project_root: &Path) -> PathBuf {
        project_root.join(crate::rename::LOCK_FILE)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FakeOs {
    Linux,
    Mac,
    Windows,
}
