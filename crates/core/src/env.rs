use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};

mod sandbox;

pub(crate) use sandbox::sandboxed;
use sandbox::{dev_home, real_home_opt_in, sandbox_vars};

/// The one spelling of the app's directory segment under config/cache/data.
const APP_DIR: &str = "kendex";

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
    real_home: PathBuf,
    config_dir: PathBuf,
    cache_dir: PathBuf,
    data_dir: PathBuf,
    vars: BTreeMap<String, String>,
}

impl Env {
    pub fn detect() -> Result<Self> {
        let data_dir = dirs::data_dir().ok_or(CoreError::NoHomeDir)?;
        let home = dirs::home_dir().ok_or(CoreError::NoHomeDir)?;
        let machine = Env {
            real_home: home.clone(),
            home,
            config_dir: dirs::config_dir().ok_or(CoreError::NoHomeDir)?,
            cache_dir: dirs::cache_dir().ok_or(CoreError::NoHomeDir)?,
            data_dir: data_dir.clone(),
            vars: BTreeMap::new(),
        };
        let vars = HARNESS_VARS
            .iter()
            .filter_map(|k| std::env::var(k).ok().map(|v| ((*k).to_owned(), v)))
            .collect();
        let dev = dev_home(
            cfg!(debug_assertions),
            real_home_opt_in().as_deref(),
            &data_dir,
        );
        Ok(Self::resolve(dev, machine, vars))
    }

    /// The whole decision with the process read out of it: given the
    /// machine's own roots, the vars this build was launched with, and the
    /// home a sandbox would give it, the environment it runs in. `detect`
    /// keeps only the reading, so there is nothing in it left to get wrong.
    fn resolve(dev_home: Option<PathBuf>, machine: Env, vars: BTreeMap<String, String>) -> Self {
        let Some(home) = dev_home else {
            return Env { vars, ..machine };
        };
        let mut env = Self::rooted(home, HOST_OS);
        env.real_home = machine.home;
        for (key, value) in sandbox_vars(vars) {
            env = env.with_var(&key, &value);
        }
        env
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

    /// This machine's own layout under a home of your choosing. A test
    /// that runs the binary against a temporary home asks here for the
    /// paths that run will write, instead of spelling them a second
    /// time: a spelling agrees with the code until a platform makes the
    /// two disagree, and the data dir is one that does.
    pub fn host_rooted(home: impl Into<PathBuf>) -> Self {
        Self::rooted(home.into(), HOST_OS)
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
            real_home: home.clone(),
            home,
            config_dir: config,
            cache_dir: cache,
            data_dir: data,
            vars: BTreeMap::new(),
        }
    }

    /// A fixture whose sandbox home and real home differ, the way a debug
    /// build's do. Without it a test cannot tell the two apart, and a call
    /// that reads the wrong one still passes.
    pub fn with_real_home(mut self, home: impl Into<PathBuf>) -> Self {
        self.real_home = home.into();
        self
    }

    /// The machine's own home, which a sandbox does not move: it is where
    /// the person lives, not where this build keeps its state. Discovery
    /// asks so it does not mistake the real home for a project, and a `~`
    /// someone typed resolves to the directory they meant.
    pub fn real_home(&self) -> &Path {
        &self.real_home
    }

    fn app_config_dir(&self) -> PathBuf {
        self.config_dir.join(APP_DIR)
    }

    pub fn settings_file(&self) -> PathBuf {
        self.app_config_dir().join("settings.toml")
    }

    pub fn global_manifest_file(&self) -> PathBuf {
        self.app_config_dir().join(crate::manifest::MANIFEST_FILE)
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

    /// The app release check's last attempt and last valid feed.
    pub fn app_update_cache_file(&self) -> PathBuf {
        self.cache_dir.join(APP_DIR).join("app-update.json")
    }

    /// Cross-process lock for one release-check cache transaction.
    pub fn app_update_lock_file(&self) -> PathBuf {
        self.cache_dir.join(APP_DIR).join("app-update.lock")
    }

    /// Where an installer records the `kendex` command it installed: one
    /// absolute path, on one line.
    ///
    /// Being executable and being named `kendex` is not being kendex, so
    /// the desktop app carries a command across only when it is at the path
    /// written here. `install.sh` writes it, and a replacement at that path
    /// is still the command it names, so the record is left as it is.
    pub fn installed_command_file(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("installed-command")
    }

    /// The Linux desktop AppImage `install.sh` writes — the one copy of the
    /// app the CLI is allowed to replace.
    pub fn app_image_file(&self) -> PathBuf {
        self.data_dir.join(APP_DIR).join("kendex.AppImage")
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
        project_root.join(crate::manifest::MANIFEST_FILE)
    }

    pub fn project_lock_file(project_root: &Path) -> PathBuf {
        project_root.join(crate::lock::LOCK_FILE)
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

#[cfg(test)]
mod tests {
    use super::*;

    /// The hatch permits writes to a real machine, so only the documented
    /// value spends it — a `0` or a typo reads as nobody's consent.
    /// A git base names a host and the Gemini override a read-only policy
    /// file, so a sandboxed build still reaches the fixture tree and the
    /// fixture settings its launcher pointed it at — dropping either would
    /// send it to the real ones.
    /// Every relocating var is a harness var: a name in one list and not the
    /// other would be read from the process and never dropped.
    /// The vars a sandboxed build ends up holding, and the home it holds
    /// them under. Reached through `resolve` rather than through the
    /// filter alone: dropping the carry-over from the decision would leave
    /// a filter that still passes its own test while every debug build
    /// loses the fixture git host and the fixture policy file.
    #[test]
    fn a_sandbox_resolves_to_its_own_home_and_keeps_what_is_safe() {
        let env = Env::resolve(
            Some(PathBuf::from("/data/kendex-dev")),
            Env::fake("/home/pat", FakeOs::Linux),
            BTreeMap::from([
                ("KENDEX_GIT_BASE".to_owned(), "file:///fixtures".to_owned()),
                (
                    "GEMINI_CLI_SYSTEM_SETTINGS_PATH".to_owned(),
                    "/fixtures/gemini.json".to_owned(),
                ),
                ("CODEX_HOME".to_owned(), "/home/pat/.codex".to_owned()),
            ]),
        );
        assert_eq!(env.home, PathBuf::from("/data/kendex-dev"));
        assert_eq!(env.real_home(), Path::new("/home/pat"));
        assert_eq!(env.var("KENDEX_GIT_BASE"), Some("file:///fixtures"));
        assert_eq!(
            env.var("GEMINI_CLI_SYSTEM_SETTINGS_PATH"),
            Some("/fixtures/gemini.json")
        );
        assert_eq!(env.var("CODEX_HOME"), None);
    }

    /// Without a sandbox the machine's own roots and every var stand.
    #[test]
    fn a_real_build_resolves_to_the_machine_it_is_on() {
        let env = Env::resolve(
            None,
            Env::fake("/home/pat", FakeOs::Linux),
            BTreeMap::from([("CODEX_HOME".to_owned(), "/home/pat/.codex".to_owned())]),
        );
        assert_eq!(env.home, PathBuf::from("/home/pat"));
        assert_eq!(env.real_home(), Path::new("/home/pat"));
        assert_eq!(env.var("CODEX_HOME"), Some("/home/pat/.codex"));
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
