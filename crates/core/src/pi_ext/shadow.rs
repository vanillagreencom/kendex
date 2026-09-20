//! A managed package Pi also loads from a directory kendex does not own.
//!
//! Pi loads every directory under a root's `extensions/` that carries a
//! `package.json` declaring `pi.extensions`, or an `index.ts`/`index.js`,
//! beside the packages the root's settings register. kendex installs under
//! `packages/` alone, so a copy of a managed package that a person or an
//! earlier installer left under `extensions/` runs its old code beside
//! every fix kendex ships, and both instances subscribe to every event.
//! Nothing here moves or deletes that copy: the report names it, and the
//! move is the person's.

use std::path::{Path, PathBuf};

use crate::error::Result;
use crate::names::shown;

/// The stable first token of every line this report opens with.
pub const KEY: &str = "pi-shadow-package";

/// One directory under `extensions/` that Pi loads as a second copy of a
/// managed package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShadowPackage {
    /// The managed package, as declared.
    pub name: String,
    /// Where kendex installs it, whether or not a copy is there yet.
    pub managed: PathBuf,
    /// The version the managed copy's `package.json` declares.
    pub managed_version: Option<String>,
    /// The directory Pi loads beside it.
    pub shadow: PathBuf,
    /// The version the shadow's `package.json` declares.
    pub shadow_version: Option<String>,
}

/// What a report says about one shadow, escaped for a terminal. Both
/// surfaces that print one, the update plan and the session check, spell
/// these four lines and nothing else about it, so the key line a reader
/// or a script matches has one spelling.
pub struct ShadowLines {
    /// `pi-shadow-package=<name>`.
    pub key: String,
    /// The managed copy's path and declared version.
    pub managed: String,
    /// The shadow's path and declared version.
    pub shadow: String,
    /// The one move that leaves Pi loading the managed copy alone.
    pub remedy: String,
}

impl ShadowPackage {
    pub fn lines(&self) -> ShadowLines {
        let version = |version: &Option<String>| match version {
            Some(version) => format!("version {}", shown(version)),
            None => "no version".to_owned(),
        };
        ShadowLines {
            key: format!("{KEY}={}", shown(&self.name)),
            managed: format!(
                "managed copy {} ({})",
                shown(&self.managed.display().to_string()),
                version(&self.managed_version)
            ),
            shadow: format!(
                "shadow copy {} ({})",
                shown(&self.shadow.display().to_string()),
                version(&self.shadow_version)
            ),
            remedy: format!(
                "Pi loads both copies; move {} out of {} so only the managed copy runs",
                shown(&self.shadow.display().to_string()),
                shown(&extensions_dir_of(&self.shadow).display().to_string())
            ),
        }
    }
}

/// The directory Pi auto-loads extension directories from, beside a root's
/// settings file.
pub fn extensions_dir(scope_root: &Path) -> PathBuf {
    scope_root.join("extensions")
}

fn extensions_dir_of(shadow: &Path) -> PathBuf {
    shadow
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| shadow.to_path_buf())
}

/// Every directory under the scope's `extensions/` that Pi loads as a copy
/// of the managed package `name`. A directory is one when Pi loads it at
/// all, and it is named for the package, its `package.json` names the
/// package under its current or an earlier name, or its `package.json`
/// declares the entry files the managed copy declares. An entry named
/// `index` is the file Pi loads from any bare directory, so it names the
/// directory rather than the package and matches nothing.
pub fn shadows_of(scope_root: &Path, name: &str) -> Result<Vec<ShadowPackage>> {
    let managed = super::package_path(scope_root, name)?;
    let managed_package = super::read(&managed).ok();
    let managed_entries = managed_package
        .as_ref()
        .map(|package| package_entries(&package.extensions))
        .unwrap_or_default();
    let mut names: Vec<&str> = vec![name];
    names.extend(super::legacy_names(name));
    let short = short_name(name);
    let mut shadows = Vec::new();
    let mut entries = super::files::read_dir(&extensions_dir(scope_root))?;
    entries.sort_by_key(std::fs::DirEntry::file_name);
    for entry in entries {
        let dir = entry.path();
        if !dir.is_dir() {
            continue;
        }
        let package = super::read(&dir).ok();
        let loadable = package
            .as_ref()
            .is_some_and(|package| !package.extensions.is_empty())
            || BARE_ENTRIES.iter().any(|index| dir.join(index).is_file());
        if !loadable {
            continue;
        }
        let dir_name = entry.file_name().to_string_lossy().into_owned();
        let named_for_it = dir_name == short || names.contains(&dir_name.as_str());
        let declares_it = package
            .as_ref()
            .is_some_and(|package| names.contains(&package.name.as_str()));
        let same_entries = package.as_ref().is_some_and(|package| {
            let entries = package_entries(&package.extensions);
            !entries.is_empty() && entries == managed_entries
        });
        if !(named_for_it || declares_it || same_entries) {
            continue;
        }
        shadows.push(ShadowPackage {
            name: name.to_owned(),
            managed: managed.clone(),
            managed_version: managed_package
                .as_ref()
                .and_then(|package| package.version.clone()),
            shadow: dir,
            shadow_version: package.and_then(|package| package.version),
        });
    }
    Ok(shadows)
}

/// The files Pi loads from a directory carrying no `package.json`.
const BARE_ENTRIES: &[&str] = &["index.ts", "index.js"];

/// The unscoped part of an npm name: `pi-hooks` for `@vanillagreen/pi-hooks`.
fn short_name(name: &str) -> &str {
    name.rsplit('/').next().unwrap_or(name)
}

/// The declared entry files as one comparable set: spelled without a
/// leading `./`, and without the entries that name a directory's default
/// file rather than a package.
fn package_entries(extensions: &[String]) -> std::collections::BTreeSet<String> {
    extensions
        .iter()
        .map(|entry| entry.trim_start_matches("./").to_owned())
        .filter(|entry| {
            Path::new(entry)
                .file_stem()
                .is_none_or(|stem| stem != "index")
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    fn package_json(name: &str, version: &str, entries: &[&str]) -> String {
        let entries: Vec<String> = entries.iter().map(|entry| format!("\"{entry}\"")).collect();
        format!(
            "{{\"name\": \"{name}\", \"version\": \"{version}\", \"pi\": {{\"extensions\": [{}]}}}}",
            entries.join(", ")
        )
    }

    const MANAGED: &str = "@vanillagreen/pi-session-bridge";

    /// A root with the managed package installed, and one file the row
    /// puts under `extensions/<dir_name>/`.
    fn root_with(dir_name: &str, file: &str, text: &str) -> (tempfile::TempDir, PathBuf) {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join(".pi/agent");
        write(
            &root.join("packages/@vanillagreen/pi-session-bridge/package.json"),
            &package_json(MANAGED, "2.0.1", &["./extensions/session-bridge.ts"]),
        );
        write(&root.join("extensions").join(dir_name).join(file), text);
        (tmp, root)
    }

    /// One directory under `extensions/`: its name, the one file in it,
    /// and the version a found shadow declares, `None` for no shadow.
    struct Row {
        case: &'static str,
        dir_name: &'static str,
        file: &'static str,
        text: String,
        expected: Option<Option<&'static str>>,
    }

    fn declaring(
        case: &'static str,
        dir_name: &'static str,
        name: &str,
        version: &'static str,
        entries: &[&str],
        expected: Option<Option<&'static str>>,
    ) -> Row {
        Row {
            case,
            dir_name,
            file: "package.json",
            text: package_json(name, version, entries),
            expected,
        }
    }

    /// Each way a directory under `extensions/` is a second copy of the
    /// managed package, and each way it is not.
    #[test]
    fn a_shadow_is_found_by_directory_name_package_name_or_entry_files() {
        let rows = [
            declaring(
                "named for the package, declaring another name",
                "pi-session-bridge",
                "@vstack/pi-session-bridge",
                "1.1.1",
                &["./src/index.ts"],
                Some(Some("1.1.1")),
            ),
            Row {
                case: "named for the package, bare index file",
                dir_name: "pi-session-bridge",
                file: "index.ts",
                text: "export default () => {};\n".to_owned(),
                expected: Some(None),
            },
            declaring(
                "declaring the managed name in another directory",
                "bridge",
                MANAGED,
                "1.0.0",
                &["./src/index.ts"],
                Some(Some("1.0.0")),
            ),
            declaring(
                "declaring an earlier name in another directory",
                "bridge",
                "pi-session-bridge",
                "0.9.0",
                &["./src/index.ts"],
                Some(Some("0.9.0")),
            ),
            declaring(
                "declaring the managed copy's entry files under another name",
                "bridge",
                "@vstack/bridge",
                "1.1.1",
                &["extensions/session-bridge.ts"],
                Some(Some("1.1.1")),
            ),
            declaring(
                "another package whose only entry is a directory default",
                "my-tool",
                "my-tool",
                "0.1.0",
                &["./extensions/index.ts"],
                None,
            ),
            declaring(
                "another package with its own entry file",
                "my-tool",
                "my-tool",
                "0.1.0",
                &["./extensions/my-tool.ts"],
                None,
            ),
            Row {
                case: "named for the package but nothing Pi loads",
                dir_name: "pi-session-bridge",
                file: "README.md",
                text: "moved aside\n".to_owned(),
                expected: None,
            },
        ];
        for row in &rows {
            let case = row.case;
            let (_tmp, root) = root_with(row.dir_name, row.file, &row.text);
            let found = shadows_of(&root, MANAGED).unwrap();
            let Some(version) = row.expected else {
                assert!(found.is_empty(), "{case}: {found:?}");
                continue;
            };
            assert_eq!(found.len(), 1, "{case}: {found:?}");
            let shadow = &found[0];
            assert_eq!(shadow.name, MANAGED, "{case}");
            assert_eq!(
                shadow.managed,
                root.join("packages/@vanillagreen/pi-session-bridge"),
                "{case}"
            );
            assert_eq!(shadow.managed_version.as_deref(), Some("2.0.1"), "{case}");
            assert_eq!(
                shadow.shadow,
                root.join("extensions").join(row.dir_name),
                "{case}"
            );
            assert_eq!(shadow.shadow_version.as_deref(), version, "{case}");
        }
    }

    /// A root with no `extensions/` directory at all, which is most of
    /// them, and one whose managed copy is not installed yet.
    #[test]
    fn no_extensions_directory_is_no_shadow_and_an_uninstalled_package_still_has_one() {
        let tmp = tempfile::tempdir().unwrap();
        let root = tmp.path().join(".pi/agent");
        assert_eq!(shadows_of(&root, "pi-widgets").unwrap(), Vec::new());

        write(
            &root.join("extensions/pi-widgets/package.json"),
            &package_json("pi-widgets", "1.0.0", &["./index.js"]),
        );
        let found = shadows_of(&root, "pi-widgets").unwrap();
        assert_eq!(found.len(), 1, "{found:?}");
        assert_eq!(found[0].managed_version, None);
        assert_eq!(found[0].shadow_version.as_deref(), Some("1.0.0"));
    }

    /// The four lines open on the key, name both copies with their
    /// versions, and name the directory to move and where out of.
    #[test]
    fn the_lines_open_on_the_key_and_name_both_copies() {
        let shadow = ShadowPackage {
            name: "pi-widgets".to_owned(),
            managed: PathBuf::from("/h/.pi/agent/packages/pi-widgets"),
            managed_version: Some("2.0.0".to_owned()),
            shadow: PathBuf::from("/h/.pi/agent/extensions/pi-widgets"),
            shadow_version: None,
        };
        let lines = shadow.lines();
        assert_eq!(lines.key, "pi-shadow-package=pi-widgets");
        assert_eq!(
            lines.managed,
            "managed copy /h/.pi/agent/packages/pi-widgets (version 2.0.0)"
        );
        assert_eq!(
            lines.shadow,
            "shadow copy /h/.pi/agent/extensions/pi-widgets (no version)"
        );
        assert_eq!(
            lines.remedy,
            "Pi loads both copies; move /h/.pi/agent/extensions/pi-widgets out of /h/.pi/agent/extensions so only the managed copy runs"
        );
    }
}
