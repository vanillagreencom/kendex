use std::path::Path;

use serde_json::{Value, json};

use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, line_terminator, read_if_exists};

/// The `packages` entry kendex writes. Pi resolves relative entries against
/// the settings file's own directory, so one shape works in both scopes.
fn entry_for(name: &str) -> String {
    format!("./packages/{name}")
}

/// True when an existing entry already refers to this package: the canonical
/// relative form, a legacy absolute path, or either wrapped in `{"source"}`.
fn refers_to(entry: &Value, name: &str) -> bool {
    let canonical = entry_for(name);
    let suffix = format!("/packages/{name}");
    let same = |text: &str| text == canonical || text.ends_with(&suffix);
    match entry {
        Value::String(text) => same(text),
        Value::Object(object) => object
            .get("source")
            .and_then(Value::as_str)
            .is_some_and(same),
        _ => false,
    }
}

/// The settings and the line terminator the file uses, which a write keeps
/// so a checkout git wrote with CRLF gets the same bytes back.
fn read(path: &Path) -> Result<(Value, &'static str)> {
    let Some(text) = read_if_exists(path)? else {
        return Ok((json!({}), "\n"));
    };
    let newline = line_terminator(&text);
    if text.trim().is_empty() {
        return Ok((json!({}), newline));
    }
    let settings = serde_json::from_str(&text).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    Ok((settings, newline))
}

fn write(path: &Path, settings: &Value, newline: &str) -> Result<()> {
    let mut text = serde_json::to_string_pretty(settings).map_err(|e| CoreError::JsonParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    text.push('\n');
    atomic_write(path, &text.replace('\n', newline))
}

fn packages_of<'a>(settings: &'a mut Value, path: &Path) -> Result<&'a mut Vec<Value>> {
    let object = settings
        .as_object_mut()
        .ok_or_else(|| not_an_object(path, "settings.json"))?;
    object
        .entry("packages")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or_else(|| not_an_object(path, "`packages`"))
}

fn not_an_object(path: &Path, what: &str) -> CoreError {
    CoreError::ConfigEdit {
        path: path.to_path_buf(),
        message: format!("pi {what} has the wrong shape"),
    }
}

/// Register the package, replacing any entry for it **in place** so a
/// reinstall never changes Pi's extension load order. An object entry with
/// keys besides `source` (Pi's `extensions` filter) keeps them under the
/// canonical source, so a disabled extension stays disabled.
pub(super) fn upsert_package(path: &Path, name: &str) -> Result<()> {
    let (mut settings, newline) = read(path)?;
    let packages = packages_of(&mut settings, path)?;
    let mut kept: Vec<Value> = Vec::with_capacity(packages.len() + 1);
    let mut slot = None;
    let mut filtered = None;
    for existing in packages.drain(..) {
        if refers_to(&existing, name) {
            if slot.is_none() {
                slot = Some(kept.len());
            }
            if let Value::Object(object) = existing
                && filtered.is_none()
                && object.keys().any(|key| key != "source")
            {
                filtered = Some(object);
            }
            continue;
        }
        kept.push(existing);
    }
    let entry = match filtered {
        Some(mut object) => {
            object.insert("source".to_owned(), Value::String(entry_for(name)));
            Value::Object(object)
        }
        None => Value::String(entry_for(name)),
    };
    match slot {
        Some(index) => kept.insert(index, entry),
        None => kept.push(entry),
    }
    *packages = kept;
    write(path, &settings, newline)
}

/// Drop every entry for the package. An emptied array is removed so the file
/// does not accumulate leftovers.
pub(super) fn remove_package(path: &Path, name: &str) -> Result<bool> {
    let (mut settings, newline) = read(path)?;
    let Some(object) = settings.as_object_mut() else {
        return Err(not_an_object(path, "settings.json"));
    };
    let Some(packages) = object.get_mut("packages").and_then(Value::as_array_mut) else {
        return Ok(false);
    };
    let before = packages.len();
    packages.retain(|entry| !refers_to(entry, name));
    if packages.len() == before {
        return Ok(false);
    }
    if packages.is_empty() {
        object.shift_remove("packages");
    }
    write(path, &settings, newline)?;
    Ok(true)
}

/// `npm:<pkg>` / `npm:<pkg>@<version>` / `npm:@scope/pkg@<version>` entries,
/// returned as bare names — the scope is part of the name, the version is not.
fn bare_npm_name(spec: &str) -> Option<String> {
    let rest = spec.strip_prefix("npm:")?;
    let bare = match rest.strip_prefix('@') {
        Some(scoped) => match scoped.find('@') {
            Some(at) => format!("@{}", &scoped[..at]),
            None => format!("@{scoped}"),
        },
        None => rest.split('@').next().unwrap_or(rest).to_owned(),
    };
    (!bare.is_empty()).then_some(bare)
}

/// Whether any `packages` entry refers to this package, in any of the forms
/// `refers_to` recognizes.
pub(super) fn references_package(path: &Path, name: &str) -> Result<bool> {
    let (settings, _) = read(path)?;
    Ok(settings
        .get("packages")
        .and_then(Value::as_array)
        .is_some_and(|entries| entries.iter().any(|entry| refers_to(entry, name))))
}

/// The npm-sourced packages Pi loads in this scope — kendex does not own
/// these, `update-pi` only reports their versions.
pub fn list_npm_entries(scope_root: &Path) -> Result<Vec<String>> {
    let path = super::settings_path(scope_root);
    let (settings, _) = read(&path)?;
    Ok(settings
        .get("packages")
        .and_then(Value::as_array)
        .map(|entries| {
            entries
                .iter()
                .filter_map(Value::as_str)
                .filter_map(bare_npm_name)
                .collect()
        })
        .unwrap_or_default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings_with(packages: &str) -> (tempfile::TempDir, std::path::PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("settings.json");
        std::fs::write(
            &path,
            format!("{{\"theme\": \"dark\", \"packages\": {packages}}}"),
        )
        .unwrap();
        (tmp, path)
    }

    fn packages(path: &Path) -> Vec<Value> {
        let text = std::fs::read_to_string(path).unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        value["packages"].as_array().cloned().unwrap_or_default()
    }

    #[test]
    fn reinstall_replaces_the_entry_in_place_and_keeps_other_keys() {
        let (_tmp, path) = settings_with(r#"["npm:first", "./packages/mine", "npm:last"]"#);
        upsert_package(&path, "mine").unwrap();
        assert_eq!(
            packages(&path),
            ["npm:first", "./packages/mine", "npm:last"]
        );
        let text = std::fs::read_to_string(&path).unwrap();
        assert!(text.contains("\"theme\""));
    }

    #[test]
    fn legacy_absolute_and_object_forms_are_the_same_entry() {
        let (_tmp, path) = settings_with(
            r#"["npm:first", {"source": "/home/u/.pi/agent/packages/@vg/pi-hooks"}, "/old/packages/@vg/pi-hooks"]"#,
        );
        upsert_package(&path, "@vg/pi-hooks").unwrap();
        assert_eq!(packages(&path), ["npm:first", "./packages/@vg/pi-hooks"]);

        assert!(remove_package(&path, "@vg/pi-hooks").unwrap());
        assert_eq!(packages(&path), ["npm:first"]);
        assert!(!remove_package(&path, "@vg/pi-hooks").unwrap());
    }

    #[test]
    fn a_reinstall_keeps_the_extension_filter_under_the_canonical_source() {
        let (_tmp, path) = settings_with(
            r#"["npm:first", {"source": "/home/u/.pi/agent/packages/pi-hooks", "extensions": []}, "npm:last"]"#,
        );
        upsert_package(&path, "pi-hooks").unwrap();
        assert_eq!(
            packages(&path),
            [
                json!("npm:first"),
                json!({"source": "./packages/pi-hooks", "extensions": []}),
                json!("npm:last"),
            ]
        );
    }

    #[test]
    fn a_new_package_appends_and_an_emptied_array_disappears() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("nested/settings.json");
        upsert_package(&path, "pi-hooks").unwrap();
        assert_eq!(packages(&path), ["./packages/pi-hooks"]);

        assert!(remove_package(&path, "pi-hooks").unwrap());
        let value: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert!(value.get("packages").is_none());
    }

    #[test]
    fn npm_entries_report_bare_names() {
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(
            tmp.path().join("settings.json"),
            r#"{"packages": ["npm:pi-tools", "npm:pi-tools@1.2.3", "npm:@vg/pi-hooks@0.1.0", "npm:@vg/pi-caveman", "./packages/local", "npm:"]}"#,
        )
        .unwrap();
        assert_eq!(
            list_npm_entries(tmp.path()).unwrap(),
            ["pi-tools", "pi-tools", "@vg/pi-hooks", "@vg/pi-caveman",]
        );
        assert!(
            list_npm_entries(&tmp.path().join("missing"))
                .unwrap()
                .is_empty()
        );
    }
}
