//! The `packages` array of Pi's `settings.json` — the registration that
//! decides whether Pi LOADS a copied package. Install, removal, and presence
//! all read and write it through here, so they cannot disagree about which
//! entry belongs to which package.

use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// Inspect a Pi `settings.json` packages array and return the entries that
/// resolve to npm specifiers (`npm:<name>` or `npm:<name>@<version>`).
/// Returns the bare package name (without version tag).
pub fn list_npm_packages(global: bool) -> Result<Vec<String>> {
    let settings_path = crate::config::pi_settings_path(global);
    if !settings_path.exists() {
        return Ok(Vec::new());
    }
    let raw = std::fs::read_to_string(&settings_path)
        .with_context(|| format!("reading {}", settings_path.display()))?;
    let parsed: serde_json::Value = serde_json::from_str(&raw)
        .with_context(|| format!("parsing {}", settings_path.display()))?;
    let packages = parsed
        .get("packages")
        .and_then(|p| p.as_array())
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for entry in packages {
        if let Some(s) = entry.as_str()
            && let Some(rest) = s.strip_prefix("npm:")
        {
            // Strip version tag (`pkg@1.2.3` or `@scope/pkg@1.2.3`).
            let bare = if let Some(rest_no_scope) = rest.strip_prefix('@') {
                // Scoped: keep `@scope/pkg`, drop trailing `@<version>` if any.
                match rest_no_scope.find('@') {
                    Some(idx) => format!("@{}", &rest_no_scope[..idx]),
                    None => format!("@{}", rest_no_scope),
                }
            } else {
                rest.split('@').next().unwrap_or(rest).to_string()
            };
            if !bare.is_empty() {
                out.push(bare);
            }
        }
    }
    Ok(out)
}

/// Will Pi LOAD this package — and, when `settings.json` cannot answer, why.
///
/// The copied directory alone proves nothing: Pi loads what its
/// `settings.json` points at, so a package whose entry was deleted or
/// repointed sits on disk and never loads — `@vanillagreen/pi-hooks` included,
/// whose session drift check then cannot report its own absence.
///
/// "The file says no" and "the file could not be read" are different faults
/// with different remedies, so they are different answers. Collapsing them
/// into `false` made an unreadable `settings.json` report every correctly
/// installed package as missing, sending users to reinstall packages that
/// were fine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PackageRegistration {
    /// `settings.json` points Pi at our copy of this package.
    Registered,
    /// `settings.json` was read and holds no entry naming our copy.
    Absent,
    /// `settings.json` could not be read or parsed, so NO package's
    /// registration can be determined from it. Names the file and the error.
    Unreadable { reason: String },
}

pub(crate) fn package_registration(name: &str, global: bool) -> PackageRegistration {
    match registered_entry_exists(name, global) {
        Ok(true) => PackageRegistration::Registered,
        Ok(false) => PackageRegistration::Absent,
        Err(err) => PackageRegistration::Unreadable {
            reason: format!("{err:#}"),
        },
    }
}

/// The bool collapse, for the one caller that asks "is there anything of this
/// package to act on?" rather than "is it correctly installed?". An unreadable
/// settings file answers `false` there because the conservative action is to
/// leave it alone. Anything REPORTING on an install must use
/// [`package_registration`] instead, so an unreadable file cannot masquerade
/// as a missing package.
pub(crate) fn package_is_registered(name: &str, global: bool) -> bool {
    matches!(
        package_registration(name, global),
        PackageRegistration::Registered
    )
}

fn registered_entry_exists(name: &str, global: bool) -> Result<bool> {
    let settings_path = crate::config::pi_settings_path(global);
    if !settings_path.exists() {
        return Ok(false);
    }
    let settings = load_or_init_settings(&settings_path)?;
    let scope = scope_dir(global);
    Ok(settings
        .get("packages")
        .and_then(|p| p.as_array())
        .is_some_and(|packages| {
            packages
                .iter()
                .any(|entry| entry_matches_package(entry, name, &scope))
        }))
}

/// The directory a relative `packages` entry resolves against: the one
/// holding `settings.json`, which is also the parent of `packages/`.
fn scope_dir(global: bool) -> PathBuf {
    crate::config::pi_packages_dir(global)
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_default()
}

/// The canonical `packages` entry vstack writes for a given package name.
fn relative_settings_entry(name: &str) -> String {
    format!("./packages/{name}")
}

/// Does this `packages` entry point Pi at OUR copy of the package?
///
/// Entries are compared by the directory they RESOLVE to, never as text: the
/// canonical `./packages/<name>`, a bare `packages/<name>`, a trailing slash,
/// an interior `.` or `..`, the absolute form legacy installs recorded, and a
/// path reaching our copy through a symlink all name the same directory, so a
/// hand-edited but still-correct entry counts — as does the ordinary macOS
/// case where the scope root itself sits under a symlink (`/tmp` →
/// `/private/tmp`, a symlinked home). Two entries that resolve to one
/// directory are ONE registration, so install replaces the alias instead of
/// adding a second entry that would load the extension twice.
///
/// A path naming any other directory does not match — including one whose
/// package name merely starts with this one's, since the lexical comparison is
/// per path component. When either side cannot be canonicalized (a target that
/// does not exist yet, a platform refusal) the lexical answer stands alone. An
/// `npm:` specifier loads a different copy of the package and never answers
/// for ours.
fn entry_matches_package(entry: &serde_json::Value, name: &str, scope_dir: &Path) -> bool {
    let installed = scope_dir.join("packages").join(name);
    let target = crate::config::normalize_path_lexical(&installed);
    let target_resolved = std::fs::canonicalize(&installed).ok();
    let matches_path = |raw: &str| {
        if raw.starts_with("npm:") {
            return false;
        }
        let path = Path::new(raw);
        let absolute = if path.is_absolute() {
            path.to_path_buf()
        } else {
            scope_dir.join(path)
        };
        if crate::config::normalize_path_lexical(&absolute) == target {
            return true;
        }
        match (&target_resolved, std::fs::canonicalize(&absolute).ok()) {
            (Some(target), Some(entry)) => &entry == target,
            _ => false,
        }
    };
    match entry {
        serde_json::Value::String(s) => matches_path(s),
        serde_json::Value::Object(obj) => obj
            .get("source")
            .and_then(|v| v.as_str())
            .is_some_and(matches_path),
        _ => false,
    }
}

/// Add a relative `./packages/<name>` entry to the `packages` array of Pi's
/// `settings.json` for the scope, preserving every other entry.
///
/// Dedupe recognizes every entry form [`entry_matches_package`] accepts, so
/// re-installs don't leave a stale duplicate behind.
pub(super) fn register_in_pi_settings(name: &str, global: bool) -> Result<()> {
    let settings_path = crate::config::pi_settings_path(global);
    if let Some(parent) = settings_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let mut settings = load_or_init_settings(&settings_path)?;
    let entry = relative_settings_entry(name);
    let scope = scope_dir(global);

    let map = settings
        .as_object_mut()
        .context("Pi settings.json is not a JSON object")?;
    if !map.contains_key("packages") {
        map.insert("packages".into(), serde_json::json!([]));
    }
    let packages = map
        .get_mut("packages")
        .and_then(|p| p.as_array_mut())
        .context("Pi settings.json `packages` is not an array")?;

    // Replace any existing entry for this package in place so reinstalling a
    // package does not change Pi extension load order. This matters when two
    // packages both customize the same UI surface (for example the editor).
    let mut replacement_index = None;
    let mut next_packages = Vec::with_capacity(packages.len() + 1);
    for existing in packages.drain(..) {
        if entry_matches_package(&existing, name, &scope) {
            if replacement_index.is_none() {
                replacement_index = Some(next_packages.len());
            }
            continue;
        }
        next_packages.push(existing);
    }

    let replacement = serde_json::Value::String(entry);
    if let Some(index) = replacement_index {
        next_packages.insert(index, replacement);
    } else {
        next_packages.push(replacement);
    }
    *packages = next_packages;

    write_settings(&settings_path, &settings)
}

/// Remove every settings entry naming this package. Returns true when
/// `settings.json` changed.
pub(super) fn unregister_from_pi_settings(name: &str, global: bool) -> Result<bool> {
    let settings_path = crate::config::pi_settings_path(global);
    if !settings_path.exists() {
        return Ok(false);
    }
    let mut settings = load_or_init_settings(&settings_path)?;
    let scope = scope_dir(global);
    let Some(map) = settings.as_object_mut() else {
        return Ok(false);
    };

    let mut changed = false;
    if let Some(packages) = map.get_mut("packages").and_then(|p| p.as_array_mut()) {
        let before = packages.len();
        packages.retain(|entry| !entry_matches_package(entry, name, &scope));
        changed = packages.len() != before;
        if packages.is_empty() {
            map.remove("packages");
            changed = true;
        }
    }

    if changed {
        write_settings(&settings_path, &settings)?;
    }
    Ok(changed)
}

fn load_or_init_settings(path: &Path) -> Result<serde_json::Value> {
    if !path.exists() {
        return Ok(serde_json::json!({}));
    }
    let content =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    if content.trim().is_empty() {
        return Ok(serde_json::json!({}));
    }
    serde_json::from_str(&content)
        .with_context(|| format!("parsing Pi settings {}", path.display()))
}

fn write_settings(path: &Path, value: &serde_json::Value) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let pretty = crate::config::to_json_pretty(value)?;
    std::fs::write(path, pretty)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_settings_entry_format() {
        assert_eq!(
            relative_settings_entry("pi-session-bridge"),
            "./packages/pi-session-bridge"
        );
        assert_eq!(relative_settings_entry("pi-qol"), "./packages/pi-qol");
    }

    #[test]
    fn entry_matches_package_for_relative_and_absolute_legacy() {
        let scope = Path::new("/var/tmp/scope");

        // Relative canonical form
        let rel = serde_json::Value::String("./packages/pi-session-bridge".into());
        assert!(entry_matches_package(&rel, "pi-session-bridge", scope));

        // Legacy absolute form
        let abs = serde_json::Value::String("/var/tmp/scope/packages/pi-session-bridge".into());
        assert!(entry_matches_package(&abs, "pi-session-bridge", scope));

        // Object form wrapping the absolute path
        let obj = serde_json::json!({
            "source": "/var/tmp/scope/packages/pi-session-bridge",
            "extensions": []
        });
        assert!(entry_matches_package(&obj, "pi-session-bridge", scope));

        // Unrelated entries don't match
        let other = serde_json::Value::String("npm:@foo/bar".into());
        assert!(!entry_matches_package(&other, "pi-session-bridge", scope));

        let other_pkg = serde_json::Value::String("./packages/pi-qol".into());
        assert!(!entry_matches_package(
            &other_pkg,
            "pi-session-bridge",
            scope
        ));
    }

    /// A hand-edited entry Pi resolves to the same directory is the same
    /// registration; one that resolves elsewhere — including a package whose
    /// name merely extends this one's — is not.
    #[test]
    fn equivalent_paths_match_and_neighbouring_names_do_not() {
        let scope = Path::new("/var/tmp/scope");
        let entry = |s: &str| serde_json::Value::String(s.into());
        for equivalent in [
            "packages/pi-hooks",
            "./packages/pi-hooks/",
            "./packages/./pi-hooks",
            "./packages/pi-qol/../pi-hooks",
            "/var/tmp/scope/./packages/pi-hooks",
        ] {
            assert!(
                entry_matches_package(&entry(equivalent), "pi-hooks", scope),
                "{equivalent} names our package directory"
            );
        }
        for other in [
            "./packages/pi-hooks-extra",
            "./packages/pi-hook",
            "./packages/@vg/pi-hooks",
            "../elsewhere/packages/pi-hooks",
            "npm:pi-hooks",
            "",
        ] {
            assert!(
                !entry_matches_package(&entry(other), "pi-hooks", scope),
                "{other} names something else"
            );
        }
        // Scoped names compare component-wise too.
        assert!(entry_matches_package(
            &entry("packages/@vg/pi-hooks"),
            "@vg/pi-hooks",
            scope
        ));
        assert!(!entry_matches_package(
            &entry("./packages/@vg/pi-hooks-extra"),
            "@vg/pi-hooks",
            scope
        ));
    }

    fn tmpdir(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "vstack_pi_settings_{label}_{}_{}",
            std::process::id(),
            crate::config::now_iso().replace([':', '-'], "")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// Pi resolves the path before loading it, so an entry that reaches our
    /// copy through a symlink IS the registration — including the ordinary
    /// case of a scope root under a symlinked path (`/tmp` → `/private/tmp`,
    /// a symlinked home), where every absolute entry recorded against the
    /// real path compares lexically unequal.
    #[cfg(unix)]
    #[test]
    fn an_entry_resolving_to_our_package_is_the_same_registration() {
        let base = tmpdir("symlinked-scope");
        let real = base.join("real-scope");
        let scope = base.join("link-scope");
        std::fs::create_dir_all(real.join("packages").join("pi-hooks")).unwrap();
        std::fs::create_dir_all(real.join("packages").join("pi-qol")).unwrap();
        std::os::unix::fs::symlink(&real, &scope).unwrap();
        let entry = |s: &str| serde_json::Value::String(s.into());

        let through_symlink = real.join("packages").join("pi-hooks");
        assert!(
            entry_matches_package(
                &entry(&through_symlink.to_string_lossy()),
                "pi-hooks",
                &scope
            ),
            "an entry Pi resolves to our copy is registered"
        );

        // Control: a genuinely different directory is still absent, resolved
        // or not.
        assert!(!entry_matches_package(
            &entry(&real.join("packages").join("pi-qol").to_string_lossy()),
            "pi-hooks",
            &scope
        ));
        // Control: a target that does not exist falls back to the lexical
        // answer — the canonical relative form still matches, a neighbour
        // still does not.
        let missing_scope = base.join("absent-scope");
        assert!(entry_matches_package(
            &entry("./packages/pi-hooks"),
            "pi-hooks",
            &missing_scope
        ));
        assert!(!entry_matches_package(
            &entry("./packages/pi-hooks-extra"),
            "pi-hooks",
            &missing_scope
        ));

        let _ = std::fs::remove_dir_all(&base);
    }

    /// One directory is one registration: reinstalling over an aliased entry
    /// replaces it in place instead of adding a second entry that would load
    /// the extension twice.
    #[cfg(unix)]
    #[test]
    fn reinstalling_over_a_resolved_alias_leaves_exactly_one_entry() {
        let base = tmpdir("symlinked-reinstall");
        let real = base.join("real-scope");
        let scope = base.join("link-scope");
        std::fs::create_dir_all(real.join("packages").join("pi-hooks")).unwrap();
        std::os::unix::fs::symlink(&real, &scope).unwrap();
        let aliased = real.join("packages").join("pi-hooks");
        std::fs::write(
            real.join("settings.json"),
            serde_json::to_string_pretty(&serde_json::json!({
                "packages": [aliased.to_string_lossy(), "./packages/pi-qol"]
            }))
            .unwrap(),
        )
        .unwrap();

        crate::test_util::with_pi_dir(&scope, || {
            register_in_pi_settings("pi-hooks", true).unwrap();
            assert!(package_is_registered("pi-hooks", true));
        });

        let written: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(real.join("settings.json")).unwrap())
                .unwrap();
        let packages = written["packages"].as_array().unwrap();
        assert_eq!(
            packages,
            &vec![
                serde_json::Value::String("./packages/pi-hooks".into()),
                serde_json::Value::String("./packages/pi-qol".into()),
            ],
            "the alias is replaced in place, not duplicated: {packages:?}"
        );

        let _ = std::fs::remove_dir_all(&base);
    }
}
