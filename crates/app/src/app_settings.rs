//! The app-settings surface: reads and writes of the app's `settings.toml`
//! (the machine-local preferences file under the app config dir, distinct
//! from a project's committed `kendex.settings.toml`), and the project
//! registry kept in it.
//!
//! Two kinds of write, and no third: `settings::mutate` for a targeted
//! change made server-side in one breath, and the whole-file
//! `update_settings`, which must present the base of the file its copy
//! was read from.

use kendex_core::base::Base;
use kendex_core::discover;
use kendex_core::engine::DriftRow;
use kendex_core::env::Env;
use kendex_core::settings::{self, AppSettings};
use serde::Serialize;
use specta::Type;

use crate::whole_file::{WriteRefused, refusal};

use crate::scopes::env;

/// The settings and the base of the exact file they describe — paired by
/// one read, or handed back by the write that produced the file. One
/// value, because a copy without its base cannot be written back safely,
/// and the two obtained apart could describe different files.
#[derive(Debug, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SettingsRead {
    pub settings: AppSettings,
    pub base: Base,
}

impl From<(AppSettings, Base)> for SettingsRead {
    fn from((settings, base): (AppSettings, Base)) -> SettingsRead {
        SettingsRead { settings, base }
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn get_settings() -> Result<SettingsRead, String> {
    let pair = settings::read_for_mutation(&env()?).map_err(|e| e.to_string())?;
    Ok(pair.into())
}

fn update_settings_at(
    env: &Env,
    mut settings: AppSettings,
    held: &Base,
) -> Result<SettingsRead, WriteRefused> {
    // A harness root is where this build applies packages, so its `~` is
    // this build's home — a sandboxed one included. The two calls that take
    // a path to a repository on the machine read the real home instead.
    for root in settings.harness_roots.values_mut() {
        *root = crate::paths::expand_tilde(&env.home, &root.to_string_lossy());
    }
    // An accepted copy is provably the file — the zoom it carries is the
    // zoom on disk, so a resize the copy predates refuses here instead of
    // being written back, and no field needs patching over from disk.
    let base = settings::replace(env, &settings, held).map_err(refusal)?;
    Ok(SettingsRead { settings, base })
}

/// Write the whole settings object back.
///
/// `base` is what the file was when this copy was read. Every settings
/// action sends the whole object, so a copy read before some other
/// surface wrote the file — a resize, a project registered in another
/// window — would put the older file back over it. A copy of a file that
/// is no longer there is refused, never applied.
#[tauri::command(async)]
#[specta::specta]
pub fn update_settings(
    settings: AppSettings,
    base: Option<String>,
) -> Result<SettingsRead, WriteRefused> {
    // The bytes behind this base were read on the settings page, so it
    // arrives as a claim and is only ever compared, never believed.
    update_settings_at(&env()?, settings, &Base::claimed(base))
}

fn save_zoom_at(env: &Env, percent: u16) -> Result<u16, String> {
    let clamped = settings::clamp_zoom(percent);
    settings::mutate(env, |settings| {
        settings.zoom = clamped;
        Ok(())
    })
    .map_err(|e| e.to_string())?;
    Ok(clamped)
}

/// The size on screen, written on its own. Nothing else in the file moves
/// with it, and nothing else can move it: a size the person is looking at
/// survives whatever else is being saved at the same moment.
#[tauri::command(async)]
#[specta::specta]
pub fn save_zoom(percent: u16) -> Result<u16, String> {
    save_zoom_at(&env()?, percent)
}

fn register_project_at(env: &Env, path: &str) -> Result<SettingsRead, String> {
    let expanded = crate::paths::expand_tilde(env.real_home(), path);
    settings::register_project(env, &expanded)
        .map(SettingsRead::from)
        .map_err(|e| e.to_string())
}

#[tauri::command(async)]
#[specta::specta]
pub fn register_project(path: String) -> Result<SettingsRead, String> {
    register_project_at(&env()?, &path)
}

/// What a project already holds that nothing manages, for the offer the
/// registration flow puts on screen. Read after the project is registered
/// rather than folded into that call: registering must not fail because a
/// scan did, and the offer is a second step the person answers.
#[tauri::command(async)]
#[specta::specta]
pub fn project_offers(root: String) -> Result<Vec<DriftRow>, String> {
    let env = env()?;
    let scope = kendex_core::model::Scope::Project {
        root: crate::paths::expand_tilde(env.real_home(), &root),
    };
    Ok(kendex_core::engine::unmanaged_here(&env, &scope))
}

#[tauri::command(async)]
#[specta::specta]
pub fn unregister_project(path: String) -> Result<SettingsRead, String> {
    settings::unregister_project(&env()?, path.as_ref())
        .map(SettingsRead::from)
        .map_err(|e| e.to_string())
}

fn discover_projects_at(env: &Env, root: &str) -> Result<Vec<String>, String> {
    let expanded = crate::paths::expand_tilde(env.real_home(), root);
    Ok(discover::discover_projects(&expanded)
        .map_err(|e| e.to_string())?
        .into_iter()
        .map(|p| p.display().to_string())
        .collect())
}

#[tauri::command(async)]
#[specta::specta]
pub fn discover_projects(root: String) -> Result<Vec<String>, String> {
    discover_projects_at(&env()?, &root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::env::FakeOs;

    fn env_in(dir: &std::path::Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    /// A debug build's shape: state under a sandbox home, the person still
    /// living in the real one. A fixture where the two coincide cannot tell
    /// a `~` read against the wrong one from a `~` read against the right
    /// one — both answers look the same.
    fn sandboxed_env_in(real_home: &std::path::Path) -> Env {
        let sandbox = real_home.join(".local/share/kendex-dev");
        std::fs::create_dir_all(&sandbox).unwrap();
        Env::fake(&sandbox, FakeOs::Linux).with_real_home(real_home)
    }

    #[test]
    fn register_project_expands_a_typed_tilde_path() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        std::fs::create_dir_all(tmp.path().join("dev/hyprtrade")).unwrap();

        let settings = register_project_at(&env, "~/dev/hyprtrade")
            .unwrap()
            .settings;
        assert_eq!(
            settings.projects,
            [kendex_core::paths::canonical(&tmp.path().join("dev/hyprtrade")).unwrap()]
        );
    }

    /// A `~` is where the person lives, and a sandbox does not move that.
    /// Resolving it against the build's own home names a directory nobody
    /// has, so the repository they picked never registers.
    #[test]
    fn register_project_reads_a_typed_tilde_against_the_real_home() {
        let tmp = tempfile::tempdir().unwrap();
        let env = sandboxed_env_in(tmp.path());
        std::fs::create_dir_all(tmp.path().join("dev/hyprtrade")).unwrap();

        let settings = register_project_at(&env, "~/dev/hyprtrade")
            .unwrap()
            .settings;
        assert_eq!(
            settings.projects,
            [kendex_core::paths::canonical(&tmp.path().join("dev/hyprtrade")).unwrap()]
        );
    }

    #[test]
    fn discover_projects_expands_a_typed_tilde_root() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        std::fs::create_dir_all(tmp.path().join("dev/app/.claude")).unwrap();

        let found = discover_projects_at(&env, "~/dev").unwrap();
        assert_eq!(
            found,
            [kendex_core::paths::canonical(&tmp.path().join("dev/app"))
                .unwrap()
                .display()
                .to_string()]
        );
    }

    #[test]
    fn discover_projects_reads_a_typed_tilde_against_the_real_home() {
        let tmp = tempfile::tempdir().unwrap();
        let env = sandboxed_env_in(tmp.path());
        std::fs::create_dir_all(tmp.path().join("dev/app/.claude")).unwrap();

        let found = discover_projects_at(&env, "~/dev").unwrap();
        assert_eq!(
            found,
            [kendex_core::paths::canonical(&tmp.path().join("dev/app"))
                .unwrap()
                .display()
                .to_string()]
        );
    }

    /// The UI cannot ask for a size outside the range, but the command is
    /// reachable with any number, and an out-of-range one reaching the file
    /// would open a window nobody can read or use.
    #[test]
    fn an_out_of_range_zoom_is_clamped_before_it_reaches_the_file() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());

        let saved = save_zoom_at(&env, 5000).unwrap();

        assert_eq!(saved, kendex_core::settings::ZOOM.max);
        assert_eq!(
            settings::load(&env).unwrap().zoom,
            kendex_core::settings::ZOOM.max
        );
    }

    /// The loss this surface used to allow: a copy read before the person
    /// resized, written back, would put the older size over the one on
    /// disk. It is refused as stale now — never applied — and the file
    /// keeps everything the copy predates.
    #[test]
    fn a_copy_from_before_a_resize_is_refused_not_applied() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let (_, held) = settings::read_for_mutation(&env).unwrap();
        save_zoom_at(&env, 150).unwrap();

        let stale = AppSettings {
            zoom: 100,
            appearance: kendex_core::settings::Appearance::Dark,
            ..AppSettings::default()
        };
        let refused = update_settings_at(&env, stale, &held).unwrap_err();

        assert!(matches!(refused, WriteRefused::Stale), "{refused:?}");
        let stored = settings::load(&env).unwrap();
        assert_eq!(stored.zoom, 150);
        assert_eq!(stored.appearance, kendex_core::settings::Appearance::System);
    }

    /// The way out of the refusal: re-read, carry the change onto the
    /// fresh copy, write with the fresh base. Nothing the copy predated is
    /// reverted.
    #[test]
    fn a_fresh_copy_carries_the_change_without_reverting_anything() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        save_zoom_at(&env, 150).unwrap();

        let (fresh, held) = settings::read_for_mutation(&env).unwrap();
        let saved = update_settings_at(
            &env,
            AppSettings {
                appearance: kendex_core::settings::Appearance::Dark,
                ..fresh
            },
            &held,
        )
        .unwrap();

        assert_eq!(saved.settings.zoom, 150);
        let stored = settings::load(&env).unwrap();
        assert_eq!(stored.zoom, 150);
        assert_eq!(stored.appearance, kendex_core::settings::Appearance::Dark);

        // And the base handed back is the file just written: the next
        // save from this copy needs no re-read.
        update_settings_at(&env, saved.settings, &saved.base).unwrap();
    }

    /// Writing the size must not roll back whatever else was saved since
    /// this size was read.
    #[test]
    fn saving_the_size_leaves_every_other_setting_alone() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let settings = AppSettings {
            appearance: kendex_core::settings::Appearance::Dark,
            ..AppSettings::default()
        };
        update_settings_at(&env, settings, &kendex_core::base::Base::absent()).unwrap();

        save_zoom_at(&env, 150).unwrap();

        let stored = settings::load(&env).unwrap();
        assert_eq!(stored.zoom, 150);
        assert_eq!(stored.appearance, kendex_core::settings::Appearance::Dark);
    }

    #[test]
    fn harness_root_overrides_expand_a_typed_tilde() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let mut settings = AppSettings::default();
        settings
            .harness_roots
            .insert("claude".into(), "~/elsewhere/.claude".into());

        let saved = update_settings_at(&env, settings, &kendex_core::base::Base::absent()).unwrap();
        assert_eq!(
            saved.settings.harness_roots.get("claude"),
            Some(&tmp.path().join("elsewhere/.claude"))
        );
    }
}
