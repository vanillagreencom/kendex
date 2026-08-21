use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

/// The one spelling of the app's directory segment under config/cache/data.
const APP_DIR: &str = "kendex";
/// Where those directories lived before the product rename — read only by
/// the first-launch move ([`crate::rename::migrate_global_dirs`]).
const LEGACY_APP_DIR: &str = "vstack2";

/// The home a debug build gets instead of the real one, under the platform
/// data dir. A build from a branch writes lock records, harness files and
/// caches the installed app cannot read; keeping them here is what stops a
/// bug reproduction from landing in the machine its author actually uses.
const DEV_HOME_DIR: &str = "kendex-dev";

/// Opts a debug build back onto the real home, for deliberate dogfooding.
const REAL_HOME_VAR: &str = "KENDEX_REAL_HOME";

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

/// The subset of [`HARNESS_VARS`] that names a directory beside the home. A
/// sandboxed build drops these and keeps the rest: an inherited CODEX_HOME
/// would aim it straight back at the real machine, while KENDEX_GIT_BASE
/// names a git host and belongs to the build wherever it runs.
const HOME_RELOCATING_VARS: [&str; 6] = [
    "CODEX_HOME",
    "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_DIR",
    "PI_CODING_AGENT_DIR",
    "COPILOT_HOME",
    "GEMINI_CLI_SYSTEM_SETTINGS_PATH",
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
        let data_dir = dirs::data_dir().ok_or(CoreError::NoHomeDir)?;
        let opt_in = std::env::var(REAL_HOME_VAR).ok();
        let vars: BTreeMap<String, String> = HARNESS_VARS
            .iter()
            .filter_map(|k| std::env::var(k).ok().map(|v| ((*k).to_owned(), v)))
            .collect();
        if let Some(home) = dev_home(cfg!(debug_assertions), opt_in.as_deref(), &data_dir) {
            let mut env = Self::rooted(home, HOST_OS);
            for (key, value) in sandbox_vars(vars) {
                env = env.with_var(&key, &value);
            }
            return Ok(env);
        }
        Ok(Env {
            home: dirs::home_dir().ok_or(CoreError::NoHomeDir)?,
            config_dir: dirs::config_dir().ok_or(CoreError::NoHomeDir)?,
            cache_dir: dirs::cache_dir().ok_or(CoreError::NoHomeDir)?,
            data_dir,
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
        Self::rooted(home.into(), os)
    }

    /// Every root under one home, laid out the way `os` lays them out.
    fn rooted(home: PathBuf, os: FakeOs) -> Self {
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

/// How this machine lays out its base directories — the same shapes
/// `dirs` resolves to, so a sandboxed home is a faithful stand-in.
const HOST_OS: FakeOs = if cfg!(target_os = "macos") {
    FakeOs::Mac
} else if cfg!(target_os = "windows") {
    FakeOs::Windows
} else {
    FakeOs::Linux
};

/// The home a build gets when it must not touch the real machine. A debug
/// build is one an agent or a contributor built from a branch, so it is the
/// one that writes records a release build cannot read; `KENDEX_REAL_HOME`
/// is how someone dogfooding says they meant the real machine.
fn dev_home(debug_build: bool, real_home_opt_in: Option<&str>, data_dir: &Path) -> Option<PathBuf> {
    let opted_in = real_home_opt_in.is_some_and(|v| !v.is_empty());
    match debug_build && !opted_in {
        true => Some(data_dir.join(DEV_HOME_DIR)),
        false => None,
    }
}

/// What a sandboxed build carries over from the process it was launched in.
fn sandbox_vars(vars: BTreeMap<String, String>) -> BTreeMap<String, String> {
    vars.into_iter()
        .filter(|(key, _)| !HOME_RELOCATING_VARS.contains(&key.as_str()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    const DATA: &str = "/data";

    #[test]
    fn a_debug_build_gets_its_own_home() {
        assert_eq!(
            dev_home(true, None, Path::new(DATA)),
            Some(PathBuf::from("/data/kendex-dev"))
        );
    }

    #[test]
    fn a_release_build_gets_the_real_home() {
        assert_eq!(dev_home(false, None, Path::new(DATA)), None);
    }

    #[test]
    fn a_debug_build_asked_for_the_real_home_gets_it() {
        assert_eq!(dev_home(true, Some("1"), Path::new(DATA)), None);
    }

    #[test]
    fn an_empty_opt_in_is_not_an_opt_in() {
        assert_eq!(
            dev_home(true, Some(""), Path::new(DATA)),
            Some(PathBuf::from("/data/kendex-dev"))
        );
        assert_eq!(dev_home(false, Some(""), Path::new(DATA)), None);
    }

    /// A git base names a host, not a directory beside the home, so a
    /// sandboxed build resolving `owner/repo` still reaches the fixture tree
    /// its launcher pointed it at.
    #[test]
    fn a_sandbox_keeps_what_does_not_point_at_a_home() {
        let vars = BTreeMap::from([
            ("KENDEX_GIT_BASE".to_owned(), "file:///fixtures".to_owned()),
            ("CODEX_HOME".to_owned(), "/home/real/.codex".to_owned()),
            ("COPILOT_HOME".to_owned(), "/home/real/.copilot".to_owned()),
        ]);
        let kept = sandbox_vars(vars);
        assert_eq!(
            kept.get("KENDEX_GIT_BASE").map(String::as_str),
            Some("file:///fixtures")
        );
        assert!(!kept.contains_key("CODEX_HOME"));
        assert!(!kept.contains_key("COPILOT_HOME"));
    }

    /// Every relocating var is a harness var: a name in one list and not the
    /// other would be read from the process and never dropped.
    #[test]
    fn every_relocating_var_is_a_harness_var() {
        for key in HOME_RELOCATING_VARS {
            assert!(HARNESS_VARS.contains(&key), "{key} is not a harness var");
        }
    }

    /// The lock, the harness dirs it applies into and the caches all hang
    /// off the roots, so redirecting the home is what moves every write.
    #[test]
    fn a_sandboxed_home_holds_every_root_it_writes() {
        let env = Env::rooted(PathBuf::from("/data/kendex-dev"), FakeOs::Linux);
        for path in [
            env.global_lock_file(),
            env.settings_file(),
            env.source_cache_dir(),
            env.journal_dir(),
            crate::harness::HarnessAdapter::default_global_root(
                &crate::harness::claude::Claude,
                &env,
            ),
        ] {
            assert!(
                path.starts_with("/data/kendex-dev"),
                "{} escaped the sandbox",
                path.display()
            );
        }
    }
}
