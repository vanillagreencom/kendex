//! Pi's extension registry: the `packages` array in a pi settings.json.
//!
//! A registered package is a folder next to the settings file, not a
//! document in a scanned surface, so what a person needs to see about it
//! — its description, where it lives, when it changed — has to be read
//! from the package itself rather than from the entry that names it.

use std::path::{Path, PathBuf};

use super::RawEntry;
use super::readers::read_json;

pub(super) fn pi_packages(path: &Path) -> Result<Vec<RawEntry>, super::ScanProblem> {
    let value = read_json(path)?;
    let Some(packages) = value.get("packages").and_then(|p| p.as_array()) else {
        return Ok(Vec::new());
    };
    // Pi resolves a relative spec against the settings file's own directory
    // (see pi_ext::settings::entry_for), so that is the only directory
    // this reader ever has to check.
    let settings_dir = path.parent();
    Ok(packages
        .iter()
        .filter_map(|entry| match entry {
            serde_json::Value::String(spec) => Some(spec.clone()),
            other => other
                .get("source")
                .and_then(|s| s.as_str())
                .map(str::to_owned),
        })
        .map(|spec| {
            let local = settings_dir.and_then(|dir| pi_local_package(dir, &spec));
            RawEntry {
                name: pi_package_name(&spec),
                enabled: None,
                description: local
                    .as_ref()
                    .and_then(|(_, description)| description.clone())
                    .or_else(|| Some(spec.clone())),
                source_path: local.map(|(dir, _)| dir),
            }
        })
        .collect())
}

/// A relative spec (`./packages/x`, `../x`) names a folder next to the
/// settings file; `npm:...` and URL specs have no local folder. Returns the
/// resolved folder plus its package.json `description`, when both exist —
/// tolerant of a missing or malformed package.json so an install that never
/// wrote one still resolves to its own directory.
fn pi_local_package(settings_dir: &Path, spec: &str) -> Option<(PathBuf, Option<String>)> {
    if !(spec.starts_with("./") || spec.starts_with("../")) {
        return None;
    }
    let rest = spec.strip_prefix("./").unwrap_or(spec);
    let dir = settings_dir.join(rest);
    if !dir.is_dir() {
        return None;
    }
    let description = read_json(&dir.join("package.json"))
        .ok()
        .and_then(|pkg| pkg.get("description")?.as_str().map(str::to_owned))
        .filter(|d| !d.is_empty());
    Some((dir, description))
}

/// `npm:@scope/pkg@1.0` → `@scope/pkg`, `./packages/x` → `x`,
/// `https://host/a/b` → `b`, anything else verbatim.
fn pi_package_name(spec: &str) -> String {
    if let Some(rest) = spec.strip_prefix("npm:") {
        let version_at = match rest.strip_prefix('@') {
            Some(scoped) => scoped.find('@').map(|i| i + 1),
            None => rest.find('@'),
        };
        return match version_at {
            Some(i) => rest[..i].to_owned(),
            None => rest.to_owned(),
        };
    }
    if spec.contains('/')
        && let Some(last) = spec.trim_end_matches('/').rsplit('/').next()
    {
        return last.to_owned();
    }
    spec.to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pi_package_names_cover_every_spec_shape() {
        assert_eq!(
            pi_package_name("npm:@vanillagreen/pi-hooks@1.2.0"),
            "@vanillagreen/pi-hooks"
        );
        assert_eq!(pi_package_name("npm:plain@2"), "plain");
        assert_eq!(pi_package_name("npm:plain"), "plain");
        assert_eq!(pi_package_name("./packages/pi-tmux"), "pi-tmux");
        assert_eq!(pi_package_name("https://github.com/a/b"), "b");
        assert_eq!(pi_package_name("odd"), "odd");
    }

    #[test]
    fn a_local_pi_package_gets_its_own_description_and_directory() {
        let tmp = tempfile::tempdir().unwrap();
        let settings = tmp.path().join("settings.json");
        std::fs::create_dir_all(tmp.path().join("packages/@vg/caveman")).unwrap();
        std::fs::write(
            tmp.path().join("packages/@vg/caveman/package.json"),
            r#"{"description": "Native Pi caveman communication mode"}"#,
        )
        .unwrap();
        std::fs::write(&settings, r#"{"packages": ["./packages/@vg/caveman"]}"#).unwrap();

        let entries = pi_packages(&settings).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(
            entries[0].description.as_deref(),
            Some("Native Pi caveman communication mode")
        );
        assert_eq!(
            entries[0].source_path.as_deref(),
            Some(tmp.path().join("packages/@vg/caveman").as_path())
        );
    }

    #[test]
    fn a_relative_pi_package_with_no_folder_falls_back_to_the_spec() {
        let tmp = tempfile::tempdir().unwrap();
        let settings = tmp.path().join("settings.json");
        std::fs::write(&settings, r#"{"packages": ["./packages/pi-tmux"]}"#).unwrap();

        let entries = pi_packages(&settings).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(
            entries[0].description.as_deref(),
            Some("./packages/pi-tmux")
        );
        assert_eq!(entries[0].source_path, None);
    }

    #[test]
    fn an_npm_pi_package_is_unaffected_by_local_resolution() {
        let tmp = tempfile::tempdir().unwrap();
        let settings = tmp.path().join("settings.json");
        std::fs::write(
            &settings,
            r#"{"packages": ["npm:@vanillagreen/pi-hooks@1.2.0"]}"#,
        )
        .unwrap();

        let entries = pi_packages(&settings).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].name, "@vanillagreen/pi-hooks");
        assert_eq!(
            entries[0].description.as_deref(),
            Some("npm:@vanillagreen/pi-hooks@1.2.0")
        );
        assert_eq!(entries[0].source_path, None);
    }
}
