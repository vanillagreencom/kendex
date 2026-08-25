//! The zoom the app offers: the range every control and the settings file
//! are held to, and the clamp a hand-edited value passes through before
//! the document is read as settings.

use serde::{Deserialize, Serialize};
use specta::Type;

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
pub(super) fn bring_zoom_into_range(document: &mut toml::Table) {
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

#[cfg(test)]
mod tests {
    use super::super::tests::{env_in, write_settings};
    use super::super::{Appearance, load};
    use super::*;
    use crate::error::CoreError;

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
}
