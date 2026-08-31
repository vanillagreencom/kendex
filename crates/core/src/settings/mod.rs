use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::base::Base;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::model::Scope;

mod zoom;
use zoom::bring_zoom_into_range;
pub use zoom::{ZOOM, ZoomRange, clamp_zoom, zoom_scale};

/// App preferences and the project registry — one settings file, nothing else.
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
    /// Packages whose update notifications are off. Machine-local like the
    /// rest of this file: a notification preference committed to a shared
    /// repository would silence a whole team.
    #[serde(default)]
    pub ignored_updates: Vec<crate::package::updates::IgnoredUpdate>,
    /// The app version whose own notice is hidden. A later version does not
    /// inherit the mute.
    #[serde(default)]
    pub muted_app_notice: Option<String>,
    /// How large the interface draws, as a percent. Machine-local like
    /// everything else in this file: how big text needs to be belongs to
    /// the person and the display in front of them, not to a project.
    #[serde(default = "default_zoom")]
    pub zoom: u16,
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

pub fn load(env: &Env) -> Result<AppSettings> {
    let path = env.settings_file();
    match read_if_exists(&path)? {
        None => Ok(AppSettings::default()),
        Some(text) => parse(&path, &text),
    }
}

/// The settings and the base of the file they came from, from one read.
/// Read apart, the settings could be the old file's and the base the new
/// one's, and the write that follows would be accepted over the writer in
/// between.
pub fn read_for_mutation(env: &Env) -> Result<(AppSettings, Base)> {
    let path = env.settings_file();
    match read_if_exists(&path)? {
        None => Ok((AppSettings::default(), Base::absent())),
        Some(text) => Ok((parse(&path, &text)?, Base::of(&text))),
    }
}

fn parse(path: &Path, text: &str) -> Result<AppSettings> {
    let mut document = text
        .parse::<toml::Table>()
        .map_err(|e| CoreError::TomlParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;
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

/// One writer at a time, across every kendex process. The app saves
/// settings from a thread pool, and the CLI registers projects into the
/// same file from its own process; unserialized, whichever load ran first
/// writes last and puts back what the other one just changed. An OS file
/// lock beside the settings file is what both can share — it also holds
/// [`replace`]'s base check and its write together, so nothing can land
/// between the two. Distinct fds conflict under the OS lock, so it
/// serializes this process's threads as well as other processes.
fn write_lock(env: &Env) -> Result<crate::fs::LockedFile> {
    let settings = env.settings_file();
    let parent = settings
        .parent()
        .ok_or_else(|| CoreError::io(&settings, std::io::Error::other("path has no parent")))?;
    std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    let mut path = settings.into_os_string();
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

fn save(env: &Env, settings: &AppSettings) -> Result<String> {
    let text = toml::to_string_pretty(settings).map_err(|e| CoreError::TomlParse {
        path: env.settings_file(),
        message: e.to_string(),
    })?;
    atomic_write(&env.settings_file(), &text)?;
    Ok(text)
}

/// Load, change, save — one breath, under the cross-process write lock.
/// The targeted write path: a stale copy cannot reach it because the copy
/// never leaves this function, and no other writer — thread or process —
/// can land between its load and its save. Returns what was written and
/// the base of the written bytes, so a caller holding the result holds a
/// current pair.
pub fn mutate(
    env: &Env,
    change: impl FnOnce(&mut AppSettings) -> Result<()>,
) -> Result<(AppSettings, Base)> {
    let _guard = write_lock(env)?;
    let mut settings = load(env)?;
    change(&mut settings)?;
    let base = Base::of(&save(env, &settings)?);
    Ok((settings, base))
}

/// The whole-file write path: replace everything with a copy something
/// held, refusing a copy of a file that is no longer there. Returns the
/// base of the bytes written — the base for the next write from the same
/// copy. There is no way to write a whole settings object without
/// presenting the base its copy was read from.
pub fn replace(env: &Env, settings: &AppSettings, held: &Base) -> Result<Base> {
    // The lock spans the check and the write, so the file the base was
    // verified against is the file the write replaces.
    let _guard = write_lock(env)?;
    held.verify(&env.settings_file())?;
    Ok(Base::of(&save(env, settings)?))
}

/// Canonicalizes, rejects non-directories and duplicates, persists.
///
/// Through `crate::paths::canonical`, the rule discovery answers with. A
/// registry entry is what `project list` prints and what the app renders
/// on a project card, so registering a path in one spelling while
/// `project discover` reports it in another leaves two commands disagreeing
/// about one project.
pub fn register_project(env: &Env, path: &Path) -> Result<(AppSettings, Base)> {
    let canonical = crate::paths::canonical(path).map_err(|e| CoreError::io(path, e))?;
    if !canonical.is_dir() {
        return Err(CoreError::NotADirectory { path: canonical });
    }
    mutate(env, |settings| {
        if settings.projects.contains(&canonical) {
            return Err(CoreError::ProjectAlreadyRegistered { path: canonical });
        }
        settings.projects.push(canonical);
        settings.projects.sort();
        Ok(())
    })
}

/// Removes by canonical path when resolvable, else by the recorded path —
/// a registered project whose directory vanished must still be removable.
///
/// By the rule [`register_project`] wrote the entry under, since this is a
/// comparison against what that stored.
pub fn unregister_project(env: &Env, path: &Path) -> Result<(AppSettings, Base)> {
    let target = crate::paths::canonical(path).unwrap_or_else(|_| path.to_path_buf());
    mutate(env, |settings| {
        let before = settings.projects.len();
        settings.projects.retain(|p| *p != target);
        match settings.projects.len() == before {
            true => Err(CoreError::ProjectNotRegistered {
                path: target.clone(),
            }),
            false => Ok(()),
        }
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
        save(&env, &settings).unwrap();
        assert_eq!(load(&env).unwrap(), settings);
    }

    /// The lost update the write lock exists to prevent: overlapping
    /// load-change-save rounds, each writing the whole file. Every writer
    /// here opens its own lock fd — distinct file descriptions conflict
    /// under the OS lock exactly the way two processes do, so this is the
    /// cross-process interleaving, not just the thread-pool one.
    #[test]
    fn overlapping_mutates_all_survive() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let writers: Vec<_> = (0..8)
            .map(|n| {
                let env = env.clone();
                std::thread::spawn(move || {
                    mutate(&env, |settings| {
                        settings.projects.push(PathBuf::from(format!("/p{n}")));
                        Ok(())
                    })
                    .unwrap();
                })
            })
            .collect();
        for writer in writers {
            writer.join().unwrap();
        }
        assert_eq!(load(&env).unwrap().projects.len(), 8);
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

        let (settings, base) = register_project(&env, &project).unwrap();
        assert_eq!(settings.projects.len(), 1);
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
