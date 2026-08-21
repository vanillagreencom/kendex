use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};

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
    /// Where the safety score starts warning and stops installing. These
    /// live here rather than in a manifest on purpose: a manifest travels
    /// with the repository it describes, and a catalog able to lower the bar
    /// it is measured against is not being measured.
    #[serde(default)]
    pub safety: crate::quality::Thresholds,
    /// Packages whose update notifications are off. Here rather than in a
    /// manifest for the same reason as `safety`: a notification preference
    /// committed to a shared repository would silence a whole team.
    #[serde(default)]
    pub ignored_updates: Vec<crate::package::updates::IgnoredUpdate>,
    /// How large the interface draws, as a percent. Machine-local like
    /// everything else in this file: how big text needs to be belongs to
    /// the person and the display in front of them, not to a project.
    #[serde(default = "default_zoom")]
    pub zoom: u16,
}

fn default_zoom() -> u16 {
    ZOOM.default
}

/// The zoom the app offers, in percent — the number stored is the number on
/// the slider, so the settings file reads the way the control does.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
pub struct ZoomRange {
    pub min: u16,
    pub max: u16,
    /// What one press of the zoom shortcut moves.
    pub step: u16,
    pub default: u16,
}

pub const ZOOM: ZoomRange = ZoomRange {
    min: 50,
    max: 200,
    step: 10,
    default: 100,
};

/// Below the floor the app is unreadable and above the ceiling its controls
/// stop fitting the window, so neither is offered and neither is honoured: a
/// hand-edited settings file is the only way a value outside the range gets
/// this far.
pub fn clamp_zoom(percent: u16) -> u16 {
    percent.clamp(ZOOM.min, ZOOM.max)
}

/// The webview scale factor a stored zoom percent means.
pub fn zoom_scale(percent: u16) -> f64 {
    f64::from(clamp_zoom(percent)) / 100.0
}

impl Default for AppSettings {
    fn default() -> Self {
        AppSettings {
            schema: 1,
            projects: Vec::new(),
            harness_roots: BTreeMap::new(),
            appearance: Appearance::System,
            safety: crate::quality::Thresholds::default(),
            ignored_updates: Vec::new(),
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

/// Bring a hand-edited zoom into range before the document is read as
/// settings. `zoom` is a percent and a `u16`, so `-1` or `999999` would
/// fail the field's own type — and the file is one document, so that one
/// number would cost the person their theme, their projects and their
/// safety thresholds along with it.
///
/// Only a whole number is moved. `zoom = 1.5` is left exactly where it is
/// and the read refuses it: that is not a size out of range, it is not a
/// size, and guessing which number was meant is worse than saying the line
/// is wrong.
fn bring_zoom_into_range(document: &mut toml::Table) {
    let Some(toml::Value::Integer(percent)) = document.get("zoom") else {
        return;
    };
    let in_range = match u16::try_from(*percent) {
        Ok(percent) => clamp_zoom(percent),
        Err(_) if percent.is_negative() => ZOOM.min,
        Err(_) => ZOOM.max,
    };
    document.insert("zoom".to_owned(), toml::Value::Integer(in_range.into()));
}

pub fn load(env: &Env) -> Result<AppSettings> {
    let path = env.settings_file();
    match read_if_exists(&path)? {
        None => Ok(AppSettings::default()),
        Some(text) => {
            let mut document = text
                .parse::<toml::Table>()
                .map_err(|e| CoreError::TomlParse {
                    path: path.clone(),
                    message: e.to_string(),
                })?;
            bring_zoom_into_range(&mut document);
            toml::Value::Table(document)
                .try_into()
                .map_err(|e: toml::de::Error| CoreError::TomlParse {
                    path,
                    message: e.to_string(),
                })
        }
    }
}

pub fn save(env: &Env, settings: &AppSettings) -> Result<()> {
    let text = toml::to_string_pretty(settings).map_err(|e| CoreError::TomlParse {
        path: env.settings_file(),
        message: e.to_string(),
    })?;
    atomic_write(&env.settings_file(), &text)
}

/// Canonicalizes, rejects non-directories and duplicates, persists.
pub fn register_project(env: &Env, path: &Path) -> Result<AppSettings> {
    let canonical = path.canonicalize().map_err(|e| CoreError::io(path, e))?;
    if !canonical.is_dir() {
        return Err(CoreError::NotADirectory { path: canonical });
    }
    let mut settings = load(env)?;
    if settings.projects.contains(&canonical) {
        return Err(CoreError::ProjectAlreadyRegistered { path: canonical });
    }
    settings.projects.push(canonical);
    settings.projects.sort();
    save(env, &settings)?;
    Ok(settings)
}

/// Removes by canonical path when resolvable, else by the recorded path —
/// a registered project whose directory vanished must still be removable.
pub fn unregister_project(env: &Env, path: &Path) -> Result<AppSettings> {
    let target = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let mut settings = load(env)?;
    let before = settings.projects.len();
    settings.projects.retain(|p| *p != target);
    if settings.projects.len() == before {
        return Err(CoreError::ProjectNotRegistered { path: target });
    }
    save(env, &settings)?;
    Ok(settings)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::env::FakeOs;

    fn env_in(dir: &Path) -> Env {
        Env::fake(dir, FakeOs::Linux)
    }

    fn write_settings(env: &Env, text: &str) {
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

    #[test]
    fn register_rejects_duplicates_and_unregister_removes() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let project = tmp.path().join("proj");
        std::fs::create_dir(&project).unwrap();

        let settings = register_project(&env, &project).unwrap();
        assert_eq!(settings.projects.len(), 1);
        assert!(matches!(
            register_project(&env, &project),
            Err(CoreError::ProjectAlreadyRegistered { .. })
        ));

        let settings = unregister_project(&env, &project).unwrap();
        assert!(settings.projects.is_empty());
        assert!(matches!(
            unregister_project(&env, &project),
            Err(CoreError::ProjectNotRegistered { .. })
        ));
    }

    #[test]
    fn a_settings_file_without_zoom_reads_as_full_size() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        write_settings(&env, "schema = 1\n");
        assert_eq!(load(&env).unwrap().zoom, 100);
    }

    #[test]
    fn a_hand_edited_zoom_outside_the_range_loads_clamped() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        write_settings(&env, "schema = 1\nzoom = 5000\n");
        assert_eq!(load(&env).unwrap().zoom, ZOOM.max);
        write_settings(&env, "schema = 1\nzoom = 1\n");
        assert_eq!(load(&env).unwrap().zoom, ZOOM.min);
    }

    /// A number the field's own type cannot hold fails the parse, and the
    /// file is one document, so a mistyped zoom would take the theme, the
    /// projects and the safety thresholds down with it.
    #[test]
    fn a_hand_edited_zoom_too_big_for_a_percent_clamps_without_losing_the_file() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let rest = "schema = 1\nappearance = \"dark\"\n";

        write_settings(&env, &format!("{rest}zoom = 999999\n"));
        let settings = load(&env).unwrap();
        assert_eq!(settings.zoom, ZOOM.max);
        assert_eq!(settings.appearance, Appearance::Dark);

        write_settings(&env, &format!("{rest}zoom = -1\n"));
        let settings = load(&env).unwrap();
        assert_eq!(settings.zoom, ZOOM.min);
        assert_eq!(settings.appearance, Appearance::Dark);
    }

    /// The line between the two: a number outside the range is a size the
    /// app will not give you, and anything that is not a whole number is
    /// not a size at all.
    #[test]
    fn a_zoom_that_is_not_a_whole_number_is_refused() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        for line in ["zoom = 1.5", "zoom = \"big\"", "zoom = true"] {
            write_settings(&env, &format!("schema = 1\n{line}\n"));
            assert!(
                matches!(load(&env), Err(CoreError::TomlParse { .. })),
                "expected {line} to be refused as the wrong kind of value"
            );
        }
    }

    #[test]
    fn zoom_scales_the_webview_by_the_percent_shown() {
        assert_eq!(zoom_scale(100), 1.0);
        assert_eq!(zoom_scale(150), 1.5);
        assert_eq!(zoom_scale(50), 0.5);
        // Out of range never reaches the window.
        assert_eq!(zoom_scale(5000), 2.0);
    }

    #[test]
    fn vanished_project_is_still_removable() {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let project = tmp.path().join("gone");
        std::fs::create_dir(&project).unwrap();
        let registered = register_project(&env, &project).unwrap().projects[0].clone();
        std::fs::remove_dir(&project).unwrap();

        let settings = unregister_project(&env, &registered).unwrap();
        assert!(settings.projects.is_empty());
    }
}
