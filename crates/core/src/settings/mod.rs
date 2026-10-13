use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::base::Base;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, atomic_write_durable, read_if_exists};
use crate::model::Scope;

mod relocate;
pub use relocate::{Confirm, Relocation, Standing, inspect, relocate_project};

mod temporary;
pub use temporary::{Temporary, refuse_temporary, temporary};

mod zoom;
use zoom::bring_zoom_into_range;
pub use zoom::{ZOOM, ZoomRange, clamp_zoom, zoom_scale};

/// The shared preferences and this machine's state, combined for callers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub struct AppSettings {
    pub schema: u32,
    #[serde(default)]
    pub projects: Vec<PathBuf>,
    /// Per-harness override of the global root directory, keyed by harness id.
    #[serde(default)]
    pub harness_roots: BTreeMap<String, PathBuf>,
    #[serde(default)]
    pub appearance: Appearance,
    /// Packages whose update notifications are off on every machine that
    /// shares this person's preferences.
    #[serde(default)]
    pub ignored_updates: Vec<crate::package::updates::IgnoredUpdate>,
    /// The app version whose own notice is hidden. A later version does not
    /// inherit the mute.
    #[serde(default)]
    pub muted_app_notice: Option<String>,
    /// How large the interface draws, as a percent. Shared with this
    /// person's other machines, independently of project configuration.
    #[serde(default = "default_zoom")]
    pub zoom: u16,
    /// Which version of the Terms of Service and Privacy Policy this
    /// machine accepted, and when. Kept in machine.toml and shared by both
    /// shells: the app's first-run screen and the
    /// CLI's first-run line write it, and neither asks again once it is
    /// here. [`crate::legal`] owns the rule.
    #[serde(default)]
    pub terms: Option<crate::legal::TermsAcceptance>,
    /// Whether kendex asks what to do with the files it wrote in a git
    /// project. Shared with this person's other machines, independently
    /// of project configuration, and read by both shells.
    #[serde(default, rename = "commit-offer")]
    pub commit_offer: CommitOffer,
    /// Whether the macOS app's first launch still asks to put the kendex
    /// command it carries on `PATH`. [`crate::command_link`] owns the rule.
    #[serde(default, rename = "command-link-prompt")]
    pub command_link_prompt: CommandLinkPrompt,
}

/// Whether the first-launch question about the kendex command is still to
/// be asked. Once answered it stays answered, whatever the answer and
/// whatever happens to the link afterwards: the Settings row is the way
/// back, and a question that returned would be one a person already gave.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum CommandLinkPrompt {
    #[default]
    Ask,
    Answered,
}

/// What a kendex write in a git project does about the files it left
/// behind.
///
/// There is no value that commits without asking, because the offer's
/// contract has none: kendex commits, pushes or opens a pull request only
/// after a person chose that in this run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum CommitOffer {
    #[default]
    Ask,
    Off,
}

impl CommitOffer {
    pub fn asking(self) -> bool {
        self == CommitOffer::Ask
    }
}

fn default_zoom() -> u16 {
    ZOOM.default
}

impl AppSettings {
    /// Every place this machine manages: the personal scope, then each
    /// registered project in registration order. One definition, because a
    /// surface that built the list itself would answer about a different
    /// set of places than the one the settings file names.
    pub fn scopes(&self) -> Vec<Scope> {
        std::iter::once(Scope::Global)
            .chain(
                self.projects
                    .iter()
                    .map(|root| Scope::Project { root: root.clone() }),
            )
            .collect()
    }
}

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            schema: 1,
            projects: Vec::new(),
            harness_roots: BTreeMap::new(),
            appearance: Appearance::System,
            ignored_updates: Vec::new(),
            muted_app_notice: None,
            zoom: ZOOM.default,
            terms: None,
            commit_offer: CommitOffer::Ask,
            command_link_prompt: CommandLinkPrompt::Ask,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}

/// Each file remembers its own bytes. A whole-object writer must present
/// both bases so an old project list cannot overwrite a newer registry.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
pub struct SettingsBase {
    pub preferences: Base,
    pub machine: Base,
}

/// Machine state stays beside the shareable preferences, under the same
/// environment-selected root. It must be excluded from shared dotfiles.
pub fn machine_file(env: &Env) -> PathBuf {
    env.settings_file().with_file_name("machine.toml")
}

// These are the retired machine keys accepted by 1.x settings.toml.
// Remove their compatibility reader at the next major release.
const MACHINE_KEYS: [&str; 3] = ["projects", "harness-roots", "terms"];

struct Read {
    settings: AppSettings,
    base: SettingsBase,
    preferences: Option<String>,
    machine: Option<String>,
    legacy: bool,
}

#[cfg(test)]
std::thread_local! {
    // A test stops the real writer at the crash boundary, without adding
    // fault configuration or a fixture API to the shipped program.
    static INTERRUPT_PREFERENCES: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

fn read(env: &Env) -> Result<Read> {
    let preferences = read_if_exists(&env.settings_file())?;
    let machine = read_if_exists(&machine_file(env))?;
    let mut settings = preferences
        .as_deref()
        .map(|text| parse(&env.settings_file(), text))
        .transpose()?
        .unwrap_or_default();
    let legacy = preferences
        .as_deref()
        .map(|text| document(&env.settings_file(), text))
        .transpose()?
        .is_some_and(|table| MACHINE_KEYS.iter().any(|key| table.contains_key(*key)));
    if let Some(text) = &machine {
        // An existing machine file wins over legacy duplicates. This is
        // also recovery after migration wrote machine state and stopped
        // before it removed the old keys from preferences.
        let local = parse(&machine_file(env), text)?;
        settings.projects = local.projects;
        settings.harness_roots = local.harness_roots;
        settings.terms = local.terms;
    }
    Ok(Read {
        settings,
        base: SettingsBase {
            preferences: preferences.as_deref().map_or_else(Base::absent, Base::of),
            machine: machine.as_deref().map_or_else(Base::absent, Base::of),
        },
        preferences,
        machine,
        legacy,
    })
}

pub fn load(env: &Env) -> Result<AppSettings> {
    Ok(read_for_mutation(env)?.0)
}

/// Read each file and its base together. Existing 1.x files migrate on
/// their first unprivileged read, under both locks, with no manual conversion.
pub fn read_for_mutation(env: &Env) -> Result<(AppSettings, SettingsBase)> {
    read_for_mutation_as(env, crate::privilege::acting_as_root())
}

fn read_for_mutation_as(env: &Env, root: bool) -> Result<(AppSettings, SettingsBase)> {
    let initial = read(env)?;
    // A read-only command can reach migration with HOME or the config
    // directory retained across sudo. Return its legacy state without
    // creating root-owned files or locks; the next unprivileged read
    // migrates it. crate::privilege owns this policy.
    if !initial.legacy || root {
        return Ok((initial.settings, initial.base));
    }
    let _machine = file_lock(&machine_file(env))?;
    let _preferences = write_lock(env)?;
    let current = read(env)?;
    if !current.legacy {
        return Ok((current.settings, current.base));
    }
    let base = save(env, &current.settings, &current)?;
    Ok((current.settings, base))
}

fn document(path: &Path, text: &str) -> Result<toml::Table> {
    text.parse::<toml::Table>()
        .map_err(|e| CoreError::TomlParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        })
}

fn parse(path: &Path, text: &str) -> Result<AppSettings> {
    let mut document = document(path, text)?;
    bring_zoom_into_range(&mut document);
    toml::Value::Table(document)
        .try_into()
        .map_err(|e: toml::de::Error| CoreError::TomlParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        })
}

/// How long a writer waits for the settings lock before giving up. A
/// settings write is a parse and one small file, so a holder alive past
/// this is stuck, and waiting on it forever would hang the caller too.
const LOCK_WAIT: std::time::Duration = std::time::Duration::from_secs(2);

/// One preferences writer at a time, across every kendex process. Both
/// settings writers take the machine lock first and this lock second.
/// Each lock holds its file's base check and write together. Distinct
/// file descriptions conflict under the OS lock, so it serializes this
/// process's threads as well as other processes.
fn write_lock(env: &Env) -> Result<crate::fs::LockedFile> {
    file_lock(&env.settings_file())
}

/// The same one-writer-at-a-time discipline over any personal file kendex
/// keeps beside the settings, so a second such file cannot grow a second
/// spelling of the lock, the wait or the refusal. [`crate::template`]'s
/// index is the other caller.
pub(crate) fn file_lock(file: &Path) -> Result<crate::fs::LockedFile> {
    let parent = file
        .parent()
        .ok_or_else(|| CoreError::io(file, std::io::Error::other("path has no parent")))?;
    std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    let mut path = file.to_path_buf().into_os_string();
    path.push(".lock");
    let path = PathBuf::from(path);
    let deadline = std::time::Instant::now() + LOCK_WAIT;
    loop {
        match crate::fs::LockedFile::try_exclusive(&path) {
            Ok(Some(lock)) => return Ok(lock),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Ok(None) => return Err(CoreError::SettingsBusy { lock: path }),
            Err(error) => return Err(CoreError::io(&path, error)),
        }
    }
}

fn documents(env: &Env, settings: &AppSettings) -> Result<(toml::Table, toml::Table)> {
    let mut preferences = toml::Table::try_from(settings).map_err(|e| CoreError::TomlParse {
        path: env.settings_file(),
        message: e.to_string(),
    })?;
    let mut machine = toml::Table::new();
    machine.insert("schema".into(), settings.schema.into());
    for key in MACHINE_KEYS {
        if let Some(value) = preferences.remove(key) {
            machine.insert(key.into(), value);
        }
    }
    Ok((preferences, machine))
}

fn encode(path: &Path, table: &toml::Table) -> Result<String> {
    toml::to_string_pretty(table).map_err(|e| CoreError::TomlParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })
}

#[allow(
    clippy::print_stderr,
    reason = "the compatibility warning must stay off stdout so CLI machine output remains valid"
)]
fn warn_legacy(env: &Env) {
    eprintln!(
        "settings: warning=legacy-machine-keys path={} replacement={}\nMachine state moves out of shared preferences on this run.",
        env.settings_file().display(),
        machine_file(env).display()
    );
}

fn save(env: &Env, settings: &AppSettings, held: &Read) -> Result<SettingsBase> {
    // Verify both before either write. The independent locks remain held
    // through both writes. Machine-first order is local to this owner;
    // its reason is visible here and needs no decision record.
    held.base.machine.verify(&machine_file(env))?;
    held.base.preferences.verify(&env.settings_file())?;
    let (preferences, machine) = documents(env, settings)?;
    let (previous_preferences, previous_machine) = documents(env, &held.settings)?;
    let mut base = held.base.clone();
    if held.legacy {
        warn_legacy(env);
    }
    // Never reverse these writes. A crash or a preferences-write failure
    // leaves complete machine state with old, readable preferences. The
    // machine reader wins over legacy duplicates left by that crash.
    if held.machine.is_none() || machine != previous_machine {
        let text = encode(&machine_file(env), &machine)?;
        atomic_write_durable(&machine_file(env), &text)?;
        base.machine = Base::of(&text);
    }
    #[cfg(test)]
    if INTERRUPT_PREFERENCES.with(|interrupt| interrupt.replace(false)) {
        return Err(CoreError::io(
            &env.settings_file(),
            std::io::Error::from(std::io::ErrorKind::Interrupted),
        ));
    }
    if held.preferences.is_none() || preferences != previous_preferences || held.legacy {
        let text = if held.legacy
            && preferences == previous_preferences
            && let Some(original) = held.preferences.as_deref()
        {
            // Remove retired keys without discarding a person's comments
            // or changing the spelling of their shared preferences.
            let mut text =
                original
                    .parse::<toml_edit::DocumentMut>()
                    .map_err(|e| CoreError::TomlParse {
                        path: env.settings_file(),
                        message: e.to_string(),
                    })?;
            for key in MACHINE_KEYS {
                text.remove(key);
            }
            text.to_string()
        } else {
            encode(&env.settings_file(), &preferences)?
        };
        atomic_write(&env.settings_file(), &text)?;
        base.preferences = Base::of(&text);
    }
    Ok(base)
}

/// Load, change, save under both cross-process write locks.
/// The targeted write path: a stale copy cannot reach it because the copy
/// never leaves this function, and no other writer — thread or process —
/// can land between its load and its save. Returns what was written and
/// the base of the written bytes, so a caller holding the result holds a
/// current pair.
pub fn mutate(
    env: &Env,
    change: impl FnOnce(&mut AppSettings) -> Result<()>,
) -> Result<(AppSettings, SettingsBase)> {
    let _machine = file_lock(&machine_file(env))?;
    let _preferences = write_lock(env)?;
    let held = read(env)?;
    let mut settings = held.settings.clone();
    change(&mut settings)?;
    let base = save(env, &settings, &held)?;
    Ok((settings, base))
}

/// The whole-file write path: replace everything with a copy something
/// held, refusing a copy of a file that is not there. Returns the
/// base of the bytes written — the base for the next write from the same
/// copy. There is no way to write a whole settings object without
/// presenting the base its copy was read from.
pub fn replace(env: &Env, settings: &AppSettings, held: &SettingsBase) -> Result<SettingsBase> {
    // The lock spans the check and the write, so the file the base was
    // verified against is the file the write replaces.
    let _machine = file_lock(&machine_file(env))?;
    let _preferences = write_lock(env)?;
    let mut current = read(env)?;
    // Keep the caller's claim through the final checks. An editor does
    // not take our locks and may change either file during this read.
    current.base = held.clone();
    save(env, settings, &current)
}

/// Canonicalizes, rejects non-directories and duplicates, persists, and
/// answers with the root it recorded.
///
/// Through `crate::paths::canonical`, the rule discovery answers with. A
/// registry entry is what `project list` prints and what the app renders
/// on a project card, so registering a path in one spelling while
/// `project discover` reports it in another leaves two commands disagreeing
/// about one project.
///
/// The recorded root comes back with the settings because the caller asked
/// under a spelling of its own — a tilde, a trailing separator, a path
/// through a symlink — and everything that keys off the project afterwards
/// uses this one. Working it out from the returned list is a guess: two
/// registrations in flight together each see both new entries.
pub fn register_project(env: &Env, path: &Path) -> Result<(AppSettings, SettingsBase, PathBuf)> {
    let canonical = entry_for(path)?;
    let recorded = canonical.clone();
    let (settings, base) = mutate(env, |settings| {
        if settings.projects.contains(&canonical) {
            return Err(CoreError::ProjectAlreadyRegistered { path: canonical });
        }
        settings.projects.push(canonical);
        settings.projects.sort();
        Ok(())
    })?;
    Ok((settings, base, recorded))
}

/// The entry a path registers under: the one spelling every registry
/// comparison is made in, refusing anything that is not a directory.
///
/// Shared by both registration doors so a project registered by an install
/// and one registered by hand can never be two entries for one folder.
fn entry_for(path: &Path) -> Result<PathBuf> {
    let canonical = crate::paths::canonical(path).map_err(|e| CoreError::io(path, e))?;
    match canonical.is_dir() {
        true => Ok(canonical),
        false => Err(CoreError::NotADirectory { path: canonical }),
    }
}

/// What a registration wrote, and whether it had anything to write.
#[derive(Debug)]
pub struct Registration {
    pub settings: AppSettings,
    pub base: SettingsBase,
    /// The entry the registry now holds for this request, in the registry's
    /// own spelling — the root every surface keying off the project uses.
    pub root: PathBuf,
    /// False where the registry already held this root, which is a
    /// registration that had nothing to do rather than one that failed.
    pub added: bool,
}

/// Register a project the caller has just written into, answering with
/// what the registry holds either way.
///
/// [`register_project`] is the door a person opens by naming a folder, and
/// it refuses one that is already there: asking twice for the same thing is
/// a mistake worth naming. This is the door a completed install opens, and
/// there the same folder arriving twice is ordinary — a second install into
/// a project kendex already tracks has the outcome the first one had, so it
/// is a success with nothing to add rather than a refusal over a run that
/// wrote files.
///
/// Same rule, same spelling, one registry: [`entry_for`] canonicalizes both
/// doors, so a folder reached through a symlink on one and its real path on
/// the other is one entry.
pub fn ensure_project_registered(env: &Env, path: &Path) -> Result<Registration> {
    let root = entry_for(path)?;
    let mut added = false;
    let entry = root.clone();
    let (settings, base) = mutate(env, |settings| {
        if !settings.projects.contains(&entry) {
            settings.projects.push(entry.clone());
            settings.projects.sort();
            added = true;
        }
        Ok(())
    })?;
    Ok(Registration {
        settings,
        base,
        root,
        added,
    })
}

/// The registry entry `path` names, in the spelling the registry stores
/// it under.
///
/// The one judge for "which entry is this", asked by every door that acts
/// on an entry a person named: removal and reconnection both. The stored
/// spelling is tried before anything is resolved, because resolution
/// answers about what is at that path *now* — a folder registered as
/// `/work/app` and since replaced by a symlink to somewhere else resolves
/// to that somewhere else, and a caller naming the recorded path exactly
/// would be told its own entry is not registered. That is the case a
/// person is in when they reach for either door.
///
/// Resolution still answers for the aliases they type — a relative name,
/// a trailing separator, a path through a symlinked ancestor — since a
/// registry entry is written canonical (invariant 17) and none of those
/// spellings equals one until it is resolved.
fn recorded_entry(settings: &AppSettings, path: &Path) -> Result<PathBuf> {
    let written = crate::paths::as_written(path);
    if settings.projects.contains(&written) {
        return Ok(written);
    }
    let resolved = crate::paths::absolute(path);
    match settings.projects.contains(&resolved) {
        true => Ok(resolved),
        false => Err(CoreError::ProjectNotRegistered { path: resolved }),
    }
}

/// Removes the entry [`recorded_entry`] matches — a registered project
/// whose directory vanished, or whose path something else now stands at,
/// must still be removable.
///
/// Matched against the file being written rather than the copy any earlier
/// read holds, so an entry another window dropped in between is one
/// refusal here rather than a removal that took nothing away.
pub fn unregister_project(env: &Env, path: &Path) -> Result<(AppSettings, SettingsBase)> {
    mutate(env, |settings| {
        let target = recorded_entry(settings, path)?;
        settings.projects.retain(|p| *p != target);
        Ok(())
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use crate::env::FakeOs;

    pub(crate) fn env_in(dir: &Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    pub(crate) fn write_settings(env: &Env, text: &str) {
        let path = env.settings_file();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn missing_settings_file_loads_defaults() {
        let tmp = tempfile::tempdir().unwrap();
        let settings = load(&env_in(tmp.path())).unwrap();
        assert_eq!(settings, AppSettings::default());
    }

    #[test]
    fn an_elevated_legacy_read_creates_nothing_and_the_next_unprivileged_read_migrates() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let env = env_in(&home);
        // Previous settings writers produce this combined file. A sudo
        // command with retained HOME reads the invoking account's copy.
        let legacy = AppSettings {
            projects: vec![home.join("project")],
            harness_roots: BTreeMap::from([("claude".into(), home.join("claude"))]),
            terms: Some(crate::legal::TermsAcceptance {
                version: 2,
                accepted_at: "2026-10-13T00:00:00Z".into(),
            }),
            zoom: 150,
            ..AppSettings::default()
        };
        let text = toml::to_string_pretty(&legacy).unwrap();
        write_settings(&env, &text);
        let entries = || {
            std::fs::read_dir(env.settings_file().parent().unwrap())
                .unwrap()
                .map(|entry| entry.unwrap().file_name())
                .collect::<std::collections::BTreeSet<_>>()
        };
        let before = entries();

        let (settings, base) = read_for_mutation_as(&env, true).unwrap();
        assert_eq!(settings, legacy);
        assert_eq!(base.preferences, Base::of(&text));
        assert_eq!(base.machine, Base::absent());
        assert_eq!(std::fs::read_to_string(env.settings_file()).unwrap(), text);
        assert_eq!(entries(), before);
        assert!(!machine_file(&env).exists());

        let (settings, _) = read_for_mutation_as(&env, false).unwrap();
        assert_eq!(settings, legacy);
        assert!(machine_file(&env).exists());
        assert!(!read(&env).unwrap().legacy);
        assert_eq!(load(&env).unwrap(), legacy);
    }

    #[test]
    fn legacy_machine_keys_migrate_without_changing_shared_preferences() {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::test_util::rooted(&tmp);
        let env = env_in(&root);
        let settings = AppSettings {
            projects: vec![root.join("project")],
            harness_roots: BTreeMap::from([("claude".into(), root.join("claude"))]),
            terms: Some(crate::legal::TermsAcceptance {
                version: 2,
                accepted_at: "2026-10-13T00:00:00Z".into(),
            }),
            appearance: Appearance::Dark,
            zoom: 150,
            commit_offer: CommitOffer::Off,
            command_link_prompt: CommandLinkPrompt::Answered,
            muted_app_notice: Some("1.17.0".into()),
            ..AppSettings::default()
        };
        let text = format!(
            "# shared preferences\n{}",
            toml::to_string_pretty(&settings).unwrap()
        );
        write_settings(&env, &text);

        assert_eq!(load(&env).unwrap(), settings);
        let preferences = std::fs::read_to_string(env.settings_file()).unwrap();
        assert!(preferences.starts_with("# shared preferences\n"));
        let preferences = document(&env.settings_file(), &preferences).unwrap();
        for key in MACHINE_KEYS {
            assert!(!preferences.contains_key(key));
        }
        assert_eq!(preferences["appearance"].as_str(), Some("dark"));
        assert_eq!(preferences["zoom"].as_integer(), Some(150));
        assert_eq!(preferences["commit-offer"].as_str(), Some("off"));
        assert_eq!(
            preferences["command-link-prompt"].as_str(),
            Some("answered")
        );
        assert_eq!(preferences["muted-app-notice"].as_str(), Some("1.17.0"));
        assert!(preferences.contains_key("ignored-updates"));
        let machine = document(
            &machine_file(&env),
            &std::fs::read_to_string(machine_file(&env)).unwrap(),
        )
        .unwrap();
        assert!(machine.contains_key("projects"));
        assert!(machine.contains_key("harness-roots"));
        assert!(machine.contains_key("terms"));
        assert!(!machine.contains_key("appearance"));
        assert!(!read(&env).unwrap().legacy);
        assert_eq!(load(&env).unwrap(), settings);
    }

    #[test]
    fn each_file_refuses_its_own_stale_base_before_either_write() {
        for machine in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            let root = crate::test_util::rooted(&tmp);
            let env = env_in(&root);
            let (mut settings, stale) = mutate(&env, |_| Ok(())).unwrap();
            let changed = if machine {
                machine_file(&env)
            } else {
                env.settings_file()
            };
            let other = if machine {
                env.settings_file()
            } else {
                machine_file(&env)
            };
            let previous_other = std::fs::read_to_string(&other).unwrap();
            let mut external = std::fs::read_to_string(&changed).unwrap();
            external.push_str("\n# external editor\n");
            std::fs::write(&changed, &external).unwrap();
            settings.zoom = 150;
            settings.projects.push(root.join("new"));
            assert!(
                matches!(replace(&env, &settings, &stale), Err(CoreError::PlanStale { path }) if path == changed)
            );
            assert_eq!(std::fs::read_to_string(&changed).unwrap(), external);
            assert_eq!(std::fs::read_to_string(&other).unwrap(), previous_other);
            let (_, fresh) = read_for_mutation(&env).unwrap();
            replace(&env, &settings, &fresh).unwrap();
            assert_eq!(load(&env).unwrap(), settings);
        }
    }

    #[test]
    fn machine_only_changes_keep_shared_file_bytes_and_base() {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::test_util::rooted(&tmp);
        let env = env_in(&root);
        let (_, before) = mutate(&env, |_| Ok(())).unwrap();
        let text = std::fs::read_to_string(env.settings_file()).unwrap();
        let (_, after) = mutate(&env, |settings| {
            settings.projects.push(root.join("project"));
            settings.terms = Some(crate::legal::TermsAcceptance {
                version: 2,
                accepted_at: "2026-10-13T00:00:00Z".into(),
            });
            Ok(())
        })
        .unwrap();
        assert_eq!(before.preferences, after.preferences);
        assert_ne!(before.machine, after.machine);
        assert_eq!(std::fs::read_to_string(env.settings_file()).unwrap(), text);
    }

    #[test]
    fn an_interrupted_two_file_write_keeps_machine_state_and_old_preferences_readable() {
        // Both migration and an ordinary two-file mutation use the real
        // write path. A test-only interruption stops it before preferences.
        for migrating in [false, true] {
            let tmp = tempfile::tempdir().unwrap();
            let root = crate::test_util::rooted(&tmp);
            let env = env_in(&root);
            let old = AppSettings {
                zoom: 125,
                ..AppSettings::default()
            };
            let project = root.join("project");
            if migrating {
                let legacy = AppSettings {
                    projects: vec![project.clone()],
                    ..old.clone()
                };
                write_settings(&env, &toml::to_string_pretty(&legacy).unwrap());
            } else {
                mutate(&env, |settings| {
                    *settings = old.clone();
                    Ok(())
                })
                .unwrap();
            }
            let old_text = std::fs::read_to_string(env.settings_file()).unwrap();
            INTERRUPT_PREFERENCES.with(|interrupt| interrupt.set(true));
            let result = if migrating {
                read_for_mutation(&env)
            } else {
                mutate(&env, |settings| {
                    settings.projects.push(project.clone());
                    settings.zoom = 150;
                    Ok(())
                })
            };
            assert!(matches!(result, Err(CoreError::Io { .. })));
            assert_eq!(
                std::fs::read_to_string(env.settings_file()).unwrap(),
                old_text
            );
            let recovered = read(&env).unwrap().settings;
            assert_eq!(recovered.projects, [project]);
            assert_eq!(recovered.zoom, 125);
            assert_eq!(load(&env).unwrap(), recovered);
            assert!(!read(&env).unwrap().legacy);
        }
    }

    #[test]
    fn a_settings_file_written_before_the_app_notice_mutes_nothing() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        write_settings(&env, "schema = 1\n");
        assert_eq!(load(&env).unwrap().muted_app_notice, None);
    }

    #[test]
    fn settings_round_trip() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let mut settings = AppSettings {
            appearance: Appearance::Dark,
            ..AppSettings::default()
        };
        settings
            .harness_roots
            .insert("claude".into(), PathBuf::from("/custom/claude"));
        mutate(&env, |written| {
            *written = settings.clone();
            Ok(())
        })
        .unwrap();
        assert_eq!(load(&env).unwrap(), settings);
    }

    /// The lost update the write lock exists to prevent: overlapping
    /// load-change-save rounds, each writing the whole file. Every writer
    /// here opens its own lock fd — distinct file descriptions conflict
    /// under the OS lock exactly the way two processes do, so this is the
    /// cross-process interleaving, not just the thread-pool one.
    /// `SettingsBusy` is the lock's refusal of a wait past `LOCK_WAIT`, which
    /// a loaded runner can reach without any update being lost, so a refused
    /// writer tries again; the claim is only that no entry goes missing.
    #[test]
    fn overlapping_mutates_all_survive() {
        const WRITERS: usize = 8;
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let start = std::sync::Arc::new(std::sync::Barrier::new(WRITERS));
        let writers: Vec<_> = (0..WRITERS)
            .map(|n| {
                let env = env.clone();
                let start = start.clone();
                std::thread::spawn(move || {
                    start.wait();
                    loop {
                        match mutate(&env, |settings| {
                            settings.projects.push(PathBuf::from(format!("/p{n}")));
                            Ok(())
                        }) {
                            Ok(_) => break,
                            Err(CoreError::SettingsBusy { .. }) => continue,
                            Err(error) => panic!("mutate failed: {error}"),
                        }
                    }
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }
        let projects = load(&env).unwrap().projects;
        for n in 0..WRITERS {
            assert!(
                projects.contains(&PathBuf::from(format!("/p{n}"))),
                "/p{n} lost"
            );
        }
    }

    /// A holder that never lets go turns into a loud refusal, not a hang.
    #[test]
    fn a_stuck_lock_holder_is_reported_not_waited_on_forever() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let _held = write_lock(&env).unwrap();
        assert!(matches!(
            write_lock(&env),
            Err(CoreError::SettingsBusy { .. })
        ));
    }

    #[test]
    fn register_rejects_duplicates_and_unregister_removes() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let project = tmp.path().join("proj");
        std::fs::create_dir(&project).unwrap();

        let (settings, base, recorded) = register_project(&env, &project).unwrap();
        assert_eq!(settings.projects.len(), 1);
        // The root it says it recorded is the entry it stored, so a caller
        // asking under another spelling does not have to guess which of
        // the entries is its own.
        assert_eq!(settings.projects, [recorded]);
        // The pair handed back is current: presenting it to the
        // whole-file path writes without a re-read in between.
        replace(&env, &settings, &base).unwrap();
        assert!(matches!(
            register_project(&env, &project),
            Err(CoreError::ProjectAlreadyRegistered { .. })
        ));

        let (settings, _) = unregister_project(&env, &project).unwrap();
        assert!(settings.projects.is_empty());
        assert!(matches!(
            unregister_project(&env, &project),
            Err(CoreError::ProjectNotRegistered { .. })
        ));
    }

    /// The other door onto [`recorded_entry`], with a symlink standing at
    /// the recorded path. Removing an entry is exactly what a person
    /// reaches for once the folder is gone, and resolving the path first
    /// looks the entry up under whatever now stands there.
    #[cfg(unix)]
    #[test]
    fn a_project_whose_recorded_path_is_now_a_link_is_still_removable() {
        let tmp = tempfile::tempdir().unwrap();
        let home = crate::test_util::rooted(&tmp);
        let env = env_in(&home);
        let project = home.join("app");
        std::fs::create_dir(&project).unwrap();
        let recorded = register_project(&env, &project).unwrap().2;
        let moved = home.join("moved");
        std::fs::rename(&project, &moved).unwrap();
        std::os::unix::fs::symlink(&moved, &project).unwrap();

        let (settings, _) = unregister_project(&env, &recorded).unwrap();

        assert!(settings.projects.is_empty());
    }

    /// A registry holding one project, an unrelated one beside it and an
    /// unrelated setting written over both — the ground the two cases
    /// below stand on. Answers the project's canonical path.
    fn a_registry_with_one_project_in_it(root: &Path) -> (Env, PathBuf) {
        let env = env_in(root);
        let project = root.join("proj");
        std::fs::create_dir(&project).unwrap();
        let elsewhere = root.join("other");
        std::fs::create_dir(&elsewhere).unwrap();
        register_project(&env, &elsewhere).unwrap();
        mutate(&env, |settings| {
            settings.appearance = Appearance::Dark;
            Ok(())
        })
        .unwrap();

        let first = ensure_project_registered(&env, &project).unwrap();
        assert!(first.added);
        assert_eq!(first.root, project);
        (env, project)
    }

    /// The registration an install makes, asked twice for the same folder.
    /// A second install into a project kendex already tracks is a success
    /// with nothing to add — the registry holds one entry, and everything
    /// else in the file is exactly where it was.
    ///
    /// Portable, and deliberately so: repeating an install is what a person
    /// does on every platform.
    #[test]
    fn an_install_registration_adds_one_entry_however_often_it_is_asked() {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::paths::canonical(tmp.path()).unwrap();
        let (env, project) = a_registry_with_one_project_in_it(&root);

        let repeat = ensure_project_registered(&env, &project).unwrap();

        assert!(!repeat.added, "the same path added a second entry");
        assert_eq!(repeat.root, project);
        let stored = load(&env).unwrap();
        assert_eq!(stored.projects, [root.join("other"), project]);
        // Every unrelated field the registrations were written over.
        assert_eq!(stored.appearance, Appearance::Dark);
    }

    /// The same folder reached by a second spelling. Unix only: a symlink
    /// is what makes one directory answer to two names here, and Windows
    /// has no equivalent a fixture may create without a privilege the test
    /// runner does not have.
    #[cfg(unix)]
    #[test]
    fn an_install_registration_answers_one_entry_for_a_second_spelling() {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::paths::canonical(tmp.path()).unwrap();
        let (env, project) = a_registry_with_one_project_in_it(&root);
        // A person can be standing in either when they install.
        let through_a_link = root.join("link");
        std::os::unix::fs::symlink(&project, &through_a_link).unwrap();

        let repeat = ensure_project_registered(&env, &through_a_link).unwrap();

        assert!(!repeat.added, "the link added a second entry");
        assert_eq!(repeat.root, project);
        assert_eq!(load(&env).unwrap().projects, [root.join("other"), project]);
    }

    /// A destination that is not a directory is refused before the registry
    /// moves, on the install door as on the one a person opens.
    #[test]
    fn an_install_registration_refuses_a_destination_that_is_not_a_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let file = tmp.path().join("notes.md");
        std::fs::write(&file, "").unwrap();

        assert!(matches!(
            ensure_project_registered(&env, &file),
            Err(CoreError::NotADirectory { .. })
        ));
        assert!(load(&env).unwrap().projects.is_empty());
    }

    #[test]
    fn vanished_project_is_still_removable() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let project = tmp.path().join("gone");
        std::fs::create_dir(&project).unwrap();
        let registered = register_project(&env, &project).unwrap().0.projects[0].clone();
        std::fs::remove_dir(&project).unwrap();

        let (settings, _) = unregister_project(&env, &registered).unwrap();
        assert!(settings.projects.is_empty());
    }
}
