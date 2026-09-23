//! A managed package Pi also loads from `extensions/`, a directory kendex
//! does not own.
//!
//! Beside the packages a root's settings register, Pi loads what sits
//! under that root's `extensions/`: a loose module file with one of the
//! [`EXTENSION_EXTS`] spellings, a directory carrying one of
//! [`BARE_ENTRIES`], or a directory carrying a `package.json` that
//! declares `pi.extensions`, the shape the copy this module was written
//! for had: a package directory an earlier installer left there, which Pi
//! ran beside the managed copy. Pi loads the global root and the current
//! project's together (`super::session_roots`). kendex installs under
//! `packages/` alone, so a copy of a managed package that a person or an
//! earlier installer left under either `extensions/` runs its old code
//! beside every fix kendex ships, and both instances subscribe to every
//! event. Nothing here moves or deletes that copy: the report names it,
//! and the move is the person's.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, Result};
use crate::harness::pi::EXTENSION_EXTS;
use crate::model::ItemKind;

/// The stable token every report of a second copy opens on, before the
/// managed package's name: `pi-shadow-package=<name>`. `update-pi` prints
/// it as the first token of the line; `kendex check` opens the copy's own
/// text on it, after the report's per-scope prefix when more than one
/// scope is checked.
pub const KEY: &str = "pi-shadow-package";

/// The files Pi loads from a directory carrying no `package.json`.
const BARE_ENTRIES: &[&str] = &["index.ts", "index.js", "index.mts", "index.mjs"];

/// One directory or file under an `extensions/` directory that Pi loads as
/// a second copy of a managed package.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ShadowPackage {
    /// The managed package, as declared.
    pub name: String,
    /// Where kendex installs it, whether or not a copy is there yet.
    pub managed: PathBuf,
    /// The version the managed copy's `package.json` declares.
    pub managed_version: Option<String>,
    /// The `extensions/` directory the copy sits in: the scope's own, or
    /// the other root Pi loads beside it.
    pub extensions: PathBuf,
    /// The directory or file Pi loads there.
    pub shadow: PathBuf,
    /// The version the copy's `package.json` declares; a loose file
    /// declares none.
    pub shadow_version: Option<String>,
}

/// What a report says about one copy. Both surfaces that print one, the
/// update plan and the session check, spell these four lines and nothing
/// else about it, so the key line a reader or a script matches has one
/// spelling.
pub struct ShadowLines {
    /// `pi-shadow-package=<name>`.
    pub key: String,
    /// The managed copy's path and declared version.
    pub managed: String,
    /// The copy's path and declared version.
    pub shadow: String,
    /// The one move that leaves Pi loading the managed copy alone: the
    /// entry by its own name, the line above having spelled its path, and
    /// the directory to move it out of.
    pub remedy: String,
}

impl ShadowPackage {
    /// The four lines, each fragment from outside kendex passed through
    /// `shown` on its way in: a path, a name and a version come from disk,
    /// and each surface scrubs what it prints its own way.
    pub fn lines(&self, shown: impl Fn(&str) -> String) -> ShadowLines {
        let entry = self
            .shadow
            .file_name()
            .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
        let version = |version: &Option<String>| match version {
            Some(version) => format!("version {}", shown(version)),
            None => "no version".to_owned(),
        };
        let path = |path: &Path| shown(&path.display().to_string());
        ShadowLines {
            key: format!("{KEY}={}", shown(&self.name)),
            managed: format!(
                "managed copy {} ({})",
                path(&self.managed),
                version(&self.managed_version)
            ),
            shadow: format!(
                "shadow copy {} ({})",
                path(&self.shadow),
                version(&self.shadow_version)
            ),
            remedy: format!(
                "Pi loads both copies; move {} out of {} so only the managed copy runs",
                shown(&entry),
                path(&self.extensions)
            ),
        }
    }
}

/// What one scan answered: the copies found, and one error per root or
/// declared name the scan could not read, so a copy under a root that
/// reads is still named when another root does not.
#[derive(Debug, Default)]
pub struct ShadowScan {
    pub found: Vec<ShadowPackage>,
    pub errors: Vec<CoreError>,
}

impl ShadowScan {
    /// The scans of one run, one per scope in the order reported, folded
    /// so that a report names each copy once and each failure once: both
    /// scopes read the same two roots, so a copy of a package declared at
    /// both, or a directory that would not read for either, comes back
    /// from each scan. A copy is one (package, path) pair, so an entry
    /// that is a copy of two packages stays named under both; a failure
    /// is its text, which names the path or the package it is about. The
    /// first scan to answer keeps the answer and the later scans lose it.
    /// The one owner of that fold, for both verbs that print a scan.
    pub fn fold<'a>(scans: impl IntoIterator<Item = &'a mut ShadowScan>) {
        let mut copies: BTreeSet<(String, PathBuf)> = BTreeSet::new();
        let mut failures: BTreeSet<String> = BTreeSet::new();
        for scan in scans {
            scan.found
                .retain(|copy| copies.insert((copy.name.clone(), copy.shadow.clone())));
            scan.errors
                .retain(|error| failures.insert(error.to_string()));
        }
    }
}

/// Every copy Pi loads of any of the declared `names`, under the scope's
/// own `extensions/` and under each other root Pi loads beside it in this
/// session. With nothing declared nothing is read. Each directory is read
/// once and each candidate judged once against every name; the scope's
/// own root comes first, and within a root the copies come in name order.
/// A name that is not a usable package name, or a directory that will not
/// read, is one error in the answer and the rest of the scan goes on.
///
/// A candidate is a copy of a package when it is named for it (its
/// directory name, or a loose file's stem, is one of the package's names
/// under `crate::ownership::matches_name`: current or earlier, whole or
/// by its leaf), when its `package.json` names the package the same way,
/// or when its `package.json` declares the managed copy's entry files as
/// a set. A loose file is matched by name alone: a catalog entry module is
/// named for its function (`hooks.ts`, `qol.ts`), which is a name a
/// person's own file carries just as well, and no read of either file
/// tells the two apart once the copy is stale. An entry named `index` is
/// the file Pi loads from any bare directory, so it names the directory
/// rather than the package and matches nothing. Nothing here reads a
/// module file: the manifests, and a directory listing, are the whole
/// read.
pub fn shadows(scope_root: &Path, other_roots: &[PathBuf], names: &[String]) -> ShadowScan {
    let mut scan = ShadowScan::default();
    if names.is_empty() {
        return scan;
    }
    let declared: Vec<Declared> = names
        .iter()
        .filter_map(|name| match Declared::read(scope_root, name) {
            Ok(package) => Some(package),
            Err(error) => {
                scan.errors.push(error);
                None
            }
        })
        .collect();
    for root in std::iter::once(scope_root).chain(other_roots.iter().map(PathBuf::as_path)) {
        let extensions = root.join("extensions");
        let mut entries = match super::files::read_dir(&extensions) {
            Ok(entries) => entries,
            Err(error) => {
                scan.errors.push(error);
                continue;
            }
        };
        entries.sort_by_key(std::fs::DirEntry::file_name);
        for entry in entries {
            let Some(candidate) = Candidate::read(&entry.path()) else {
                continue;
            };
            for package in declared.iter().filter(|package| candidate.copies(package)) {
                scan.found.push(ShadowPackage {
                    name: package.name.clone(),
                    managed: package.managed.clone(),
                    managed_version: package.version.clone(),
                    extensions: extensions.clone(),
                    shadow: candidate.path.clone(),
                    shadow_version: candidate.version.clone(),
                });
            }
        }
    }
    scan
}

/// One declared package, with what a candidate is judged against.
struct Declared {
    name: String,
    managed: PathBuf,
    version: Option<String>,
    /// Every name the package may carry, current and earlier: the rename
    /// family of the declared spelling, so a manifest declaring an earlier
    /// name still meets a copy carrying the current one.
    names: Vec<String>,
    /// The managed copy's declared entry files, as `package_entries` keeps them.
    entries: BTreeSet<String>,
}

impl Declared {
    /// Reads the managed copy's `package.json` under `packages/`, for its
    /// version and entry files; a copy not installed yet has neither.
    fn read(scope_root: &Path, name: &str) -> Result<Declared> {
        let managed = super::package_path(scope_root, name)?;
        let package = super::read(&managed).ok();
        let entries = package
            .as_ref()
            .map(|package| package_entries(&package.extensions))
            .unwrap_or_default();
        Ok(Declared {
            name: name.to_owned(),
            managed,
            version: package.and_then(|package| package.version),
            names: super::family(name).into_iter().map(str::to_owned).collect(),
            entries,
        })
    }

    /// Whether an on-disk spelling names this package, under the one rule
    /// for a Pi extension's names.
    fn named(&self, spelling: &str) -> bool {
        self.names
            .iter()
            .any(|known| crate::ownership::matches_name(ItemKind::PiExtension, known, spelling))
    }
}

/// One entry under `extensions/` that Pi loads.
struct Candidate {
    path: PathBuf,
    version: Option<String>,
    shape: Shape,
}

enum Shape {
    /// A directory Pi loads: `package.json` with `pi.extensions`, or a bare
    /// entry file. `package` is that manifest where it reads.
    Dir {
        dir_name: String,
        package_name: Option<String>,
        entries: BTreeSet<String>,
    },
    /// A loose module file, by its stem.
    File { stem: String },
}

impl Candidate {
    /// `None` for an entry Pi does not load: a file of another kind, a
    /// directory with neither a package manifest nor a bare entry.
    fn read(path: &Path) -> Option<Candidate> {
        let file_name = path.file_name()?.to_string_lossy().into_owned();
        if path.is_dir() {
            let package = super::read(path).ok();
            let loadable = package
                .as_ref()
                .is_some_and(|package| !package.extensions.is_empty())
                || BARE_ENTRIES.iter().any(|index| path.join(index).is_file());
            if !loadable {
                return None;
            }
            let entries = package
                .as_ref()
                .map(|package| package_entries(&package.extensions))
                .unwrap_or_default();
            return Some(Candidate {
                path: path.to_path_buf(),
                version: package.as_ref().and_then(|package| package.version.clone()),
                shape: Shape::Dir {
                    dir_name: file_name,
                    package_name: package.map(|package| package.name),
                    entries,
                },
            });
        }
        if !path.is_file() {
            return None;
        }
        let module = path
            .extension()
            .is_some_and(|ext| EXTENSION_EXTS.iter().any(|known| *known == ext));
        if !module {
            return None;
        }
        Some(Candidate {
            path: path.to_path_buf(),
            version: None,
            shape: Shape::File {
                stem: stem(&file_name)?,
            },
        })
    }

    fn copies(&self, package: &Declared) -> bool {
        match &self.shape {
            Shape::Dir {
                dir_name,
                package_name,
                entries,
            } => {
                package.named(dir_name)
                    || package_name
                        .as_deref()
                        .is_some_and(|name| package.named(name))
                    || (!entries.is_empty() && *entries == package.entries)
            }
            Shape::File { stem } => package.named(stem),
        }
    }
}

/// The declared entry files as one comparable set: spelled without a
/// leading `./`, and without the entries that name a directory's default
/// file rather than a package.
fn package_entries(extensions: &[String]) -> BTreeSet<String> {
    extensions
        .iter()
        .map(|entry| entry.trim_start_matches("./").to_owned())
        .filter(|entry| stem(entry).is_some())
        .collect()
}

/// A path's file stem, `None` for the directory default `index`.
fn stem(path: &str) -> Option<String> {
    let stem = Path::new(path).file_stem()?.to_string_lossy();
    (stem != "index").then(|| stem.into_owned())
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

    /// The catalog package with an earlier name: `RENAMES` maps it to
    /// `pi-session-bridge`, which is also its unscoped name.
    const BRIDGE: &str = "@vanillagreen/pi-session-bridge";
    /// A catalog package with no earlier name.
    const NEW: &str = "@vanillagreen/pi-newthing";
    /// The managed copy's one entry file, and its bytes.
    const MANAGED_ENTRY: &str = "extensions/session-bridge.ts";
    const MANAGED_BYTES: &str = "export const managed = 1;\n";

    /// One declared package and what sits under `extensions/`: the files,
    /// as paths relative to it with their text, and the copies expected,
    /// as the same relative paths in order with the version each declares.
    struct Row {
        case: &'static str,
        name: &'static str,
        installed: bool,
        files: Vec<(&'static str, String)>,
        expected: Vec<(&'static str, Option<&'static str>)>,
    }

    /// A row with one directory under `extensions/` declaring a package.
    fn declaring(
        case: &'static str,
        name: &'static str,
        dir_name: &'static str,
        declared: &str,
        version: &'static str,
        entries: &[&str],
        found: bool,
    ) -> Row {
        let manifest = format!("{dir_name}/package.json");
        let manifest: &'static str = Box::leak(manifest.into_boxed_str());
        Row {
            case,
            name,
            installed: true,
            files: vec![(manifest, package_json(declared, version, entries))],
            expected: if found {
                vec![(dir_name, Some(version))]
            } else {
                vec![]
            },
        }
    }

    /// A row with one file under `extensions/`, loose or inside a bare
    /// directory, which declares no version.
    fn bare(case: &'static str, name: &'static str, file: &'static str, found: bool) -> Row {
        let module = "export default () => {};\n".to_owned();
        let shadow = file.split_once('/').map_or(file, |(dir, _)| dir);
        Row {
            case,
            name,
            installed: true,
            files: vec![(file, module)],
            expected: if found { vec![(shadow, None)] } else { vec![] },
        }
    }

    /// Directories carrying a `package.json`.
    fn declaring_rows() -> Vec<Row> {
        vec![
            declaring(
                "named for the package, declaring another name",
                BRIDGE,
                "pi-session-bridge",
                "@vstack/pi-session-bridge",
                "1.1.1",
                &["./src/index.ts"],
                true,
            ),
            declaring(
                "named for a package with no earlier name, declaring another name",
                NEW,
                "pi-newthing",
                "@someone/newthing",
                "0.3.0",
                &["./src/index.ts"],
                true,
            ),
            declaring(
                "declaring the managed name in another directory",
                BRIDGE,
                "bridge",
                BRIDGE,
                "1.0.0",
                &["./src/index.ts"],
                true,
            ),
            declaring(
                "declaring the unscoped name of a package with no earlier name, in another directory",
                NEW,
                "newthing-copy",
                "pi-newthing",
                "0.2.0",
                &["./src/index.ts"],
                true,
            ),
            declaring(
                "declaring an earlier name in another directory",
                BRIDGE,
                "bridge",
                "pi-session-bridge",
                "0.9.0",
                &["./src/index.ts"],
                true,
            ),
            // The manifest declares an earlier name and the copy carries
            // the current one: the family is reached through the current
            // name, so the declared spelling need not be it.
            declaring(
                "declared under an earlier name, a copy under the current one",
                "pi-session-bridge",
                "bridge",
                BRIDGE,
                "0.9.0",
                &["./src/index.ts"],
                true,
            ),
            // Two earlier names of one package, neither of which carries
            // the other: a candidate set built off the declared spelling
            // holds one name and misses the copy.
            declaring(
                "declared under one earlier name, a copy under another",
                "pi-subagents",
                "tmux",
                "pi-subagents-tmux",
                "0.4.0",
                &["./src/index.ts"],
                true,
            ),
            declaring(
                "declaring the managed copy's entry files under another name",
                BRIDGE,
                "bridge",
                "@vstack/bridge",
                "1.1.1",
                &["extensions/session-bridge.ts"],
                true,
            ),
            declaring(
                "another package whose only entry is a directory default",
                BRIDGE,
                "my-tool",
                "my-tool",
                "0.1.0",
                &["./extensions/index.ts"],
                false,
            ),
            declaring(
                "another package with its own entry file",
                BRIDGE,
                "my-tool",
                "my-tool",
                "0.1.0",
                &["./extensions/my-tool.ts"],
                false,
            ),
        ]
    }

    /// Directories with no manifest, and what one read of `extensions/`
    /// answers for a package whose managed copy is absent or has two
    /// copies.
    fn bare_directory_rows() -> Vec<Row> {
        vec![
            bare(
                "named for the package, bare index.ts",
                BRIDGE,
                "pi-session-bridge/index.ts",
                true,
            ),
            bare(
                "named for the package, bare index.js",
                BRIDGE,
                "pi-session-bridge/index.js",
                true,
            ),
            bare(
                "named for the package, bare index.mts",
                BRIDGE,
                "pi-session-bridge/index.mts",
                true,
            ),
            bare(
                "named for the package, bare index.mjs",
                BRIDGE,
                "pi-session-bridge/index.mjs",
                true,
            ),
            bare(
                "named for the package, bare index.cjs, which Pi does not load from a bare directory",
                BRIDGE,
                "pi-session-bridge/index.cjs",
                false,
            ),
            bare(
                "named for the package but nothing Pi loads",
                BRIDGE,
                "pi-session-bridge/README.md",
                false,
            ),
            Row {
                case: "another package declaring only a directory default, managed copy absent",
                name: BRIDGE,
                installed: false,
                files: vec![(
                    "my-tool/package.json",
                    package_json("my-tool", "0.1.0", &["./index.js"]),
                )],
                expected: vec![],
            },
            Row {
                case: "two copies, in name order",
                name: BRIDGE,
                installed: true,
                files: vec![
                    (
                        "zz-bridge/package.json",
                        package_json(BRIDGE, "1.2.0", &["./index.js"]),
                    ),
                    (
                        "aa-bridge/package.json",
                        package_json("pi-session-bridge", "1.1.0", &["./index.js"]),
                    ),
                ],
                expected: vec![("aa-bridge", Some("1.1.0")), ("zz-bridge", Some("1.2.0"))],
            },
        ]
    }

    /// Loose files under `extensions/`, one positive row per module
    /// spelling Pi loads, each spelled here rather than read from
    /// `EXTENSION_EXTS`, so a spelling dropped from that list reddens
    /// its own row.
    fn file_rows() -> Vec<Row> {
        vec![
            bare(
                "a loose .ts file named for the package",
                BRIDGE,
                "pi-session-bridge.ts",
                true,
            ),
            bare(
                "a loose .js file named for the package",
                BRIDGE,
                "pi-session-bridge.js",
                true,
            ),
            bare(
                "a loose .mts file named for the package",
                BRIDGE,
                "pi-session-bridge.mts",
                true,
            ),
            bare(
                "a loose .mjs file named for the package",
                BRIDGE,
                "pi-session-bridge.mjs",
                true,
            ),
            bare(
                "a loose .cts file named for the package",
                BRIDGE,
                "pi-session-bridge.cts",
                true,
            ),
            bare(
                "a loose .cjs file named for a package with no earlier name",
                NEW,
                "pi-newthing.cjs",
                true,
            ),
            Row {
                case: "a loose file carrying a managed entry's stem, the managed bytes even",
                name: BRIDGE,
                installed: true,
                files: vec![("session-bridge.mjs", MANAGED_BYTES.to_owned())],
                expected: vec![],
            },
            bare("a loose file of another name", BRIDGE, "qol.ts", false),
            bare(
                "a loose file Pi does not load",
                BRIDGE,
                "pi-session-bridge.md",
                false,
            ),
        ]
    }

    /// Each way an entry under `extensions/` is a second copy of the
    /// declared package, and each way it is not.
    #[test]
    fn a_copy_is_found_by_name_manifest_or_entry_files_as_a_directory_or_a_file() {
        for row in declaring_rows()
            .into_iter()
            .chain(bare_directory_rows())
            .chain(file_rows())
        {
            let case = row.case;
            let tmp = tempfile::tempdir().unwrap();
            let root = tmp.path().join(".pi/agent");
            let managed = super::super::package_path(&root, row.name).unwrap();
            if row.installed {
                write(
                    &managed.join("package.json"),
                    &package_json(row.name, "2.0.1", &[&format!("./{MANAGED_ENTRY}")]),
                );
                write(&managed.join(MANAGED_ENTRY), MANAGED_BYTES);
            }
            let extensions = root.join("extensions");
            for (file, text) in &row.files {
                write(&extensions.join(file), text);
            }

            let scan = shadows(&root, &[], &[row.name.to_owned()]);
            assert!(scan.errors.is_empty(), "{case}: {:?}", scan.errors);
            let found = scan.found;

            let expected: Vec<ShadowPackage> = row
                .expected
                .iter()
                .map(|(shadow, version)| ShadowPackage {
                    name: row.name.to_owned(),
                    managed: managed.clone(),
                    managed_version: row.installed.then(|| "2.0.1".to_owned()),
                    extensions: extensions.clone(),
                    shadow: extensions.join(shadow),
                    shadow_version: version.map(str::to_owned),
                })
                .collect();
            assert_eq!(found, expected, "{case}");
        }
    }

    /// A root with no `extensions/` directory at all, which is most of
    /// them, answers nothing; a copy under the other root Pi loads beside
    /// the scope is found and names that root's directory, and one read
    /// of each directory answers for every declared name.
    #[test]
    fn other_roots_are_read_and_a_missing_directory_is_no_copy() {
        let tmp = tempfile::tempdir().unwrap();
        let project = tmp.path().join("proj/.pi");
        let global = tmp.path().join(".pi/agent");
        let names = ["pi-widgets".to_owned(), "pi-other".to_owned()];
        let scan = shadows(&project, std::slice::from_ref(&global), &names);
        assert!(scan.errors.is_empty(), "{:?}", scan.errors);
        assert_eq!(scan.found, Vec::new());

        write(
            &global.join("extensions/pi-widgets/package.json"),
            &package_json("pi-widgets", "1.0.0", &["./index.js"]),
        );
        write(
            &global.join("extensions/pi-other.ts"),
            "export default () => {};\n",
        );
        let scan = shadows(&project, std::slice::from_ref(&global), &names);
        assert!(scan.errors.is_empty(), "{:?}", scan.errors);
        assert_eq!(
            scan.found,
            vec![
                ShadowPackage {
                    name: "pi-other".to_owned(),
                    managed: project.join("packages/pi-other"),
                    managed_version: None,
                    extensions: global.join("extensions"),
                    shadow: global.join("extensions/pi-other.ts"),
                    shadow_version: None,
                },
                ShadowPackage {
                    name: "pi-widgets".to_owned(),
                    managed: project.join("packages/pi-widgets"),
                    managed_version: None,
                    extensions: global.join("extensions"),
                    shadow: global.join("extensions/pi-widgets"),
                    shadow_version: Some("1.0.0".to_owned()),
                },
            ]
        );
    }

    /// A root whose `extensions` will not read as a directory is one
    /// error, and the copy under the root that reads is still found; a
    /// name that is not a usable package name is one error beside the
    /// copies of the names that are; with nothing declared nothing is
    /// read, so the unreadable root is no error either.
    #[test]
    fn an_unreadable_root_or_name_is_one_error_beside_the_copies_found() {
        let tmp = tempfile::tempdir().unwrap();
        let project = tmp.path().join("proj/.pi");
        let global = tmp.path().join(".pi/agent");
        write(&global.join("extensions"), "not a directory\n");
        write(
            &project.join("extensions/pi-widgets/package.json"),
            &package_json("pi-widgets", "1.0.0", &["./index.js"]),
        );
        let names = ["pi-widgets".to_owned(), "../escape".to_owned()];

        let scan = shadows(&project, std::slice::from_ref(&global), &names);

        assert_eq!(
            scan.found,
            vec![ShadowPackage {
                name: "pi-widgets".to_owned(),
                managed: project.join("packages/pi-widgets"),
                managed_version: None,
                extensions: project.join("extensions"),
                shadow: project.join("extensions/pi-widgets"),
                shadow_version: Some("1.0.0".to_owned()),
            }]
        );
        let errors: Vec<String> = scan.errors.iter().map(ToString::to_string).collect();
        assert_eq!(errors.len(), 2, "{errors:?}");
        assert!(errors[0].contains("../escape"), "{errors:?}");
        assert!(
            errors[1].starts_with(&global.join("extensions").display().to_string()),
            "{errors:?}"
        );

        let scan = shadows(&project, std::slice::from_ref(&global), &[]);
        assert!(scan.found.is_empty() && scan.errors.is_empty(), "{scan:?}");

        // The other order: the scope's own root will not read and the
        // copy sits under the other root, which is read after it.
        let tmp = tempfile::tempdir().unwrap();
        let project = tmp.path().join("proj/.pi");
        let global = tmp.path().join(".pi/agent");
        write(&project.join("extensions"), "not a directory\n");
        write(
            &global.join("extensions/pi-widgets/package.json"),
            &package_json("pi-widgets", "1.0.0", &["./index.js"]),
        );
        let scan = shadows(
            &project,
            std::slice::from_ref(&global),
            &["pi-widgets".to_owned()],
        );
        assert_eq!(
            scan.found,
            vec![ShadowPackage {
                name: "pi-widgets".to_owned(),
                managed: project.join("packages/pi-widgets"),
                managed_version: None,
                extensions: global.join("extensions"),
                shadow: global.join("extensions/pi-widgets"),
                shadow_version: Some("1.0.0".to_owned()),
            }]
        );
        let errors: Vec<String> = scan.errors.iter().map(ToString::to_string).collect();
        assert_eq!(errors.len(), 1, "{errors:?}");
        assert!(
            errors[0].starts_with(&project.join("extensions").display().to_string()),
            "{errors:?}"
        );
    }

    /// Two scans of one run answer the same copy and the same failure:
    /// the fold leaves each with the first scan, keeps a copy under a
    /// second package the entry is also a copy of, and keeps a failure of
    /// another text.
    #[test]
    fn the_fold_names_each_copy_and_each_failure_once_per_run() {
        let copy = |name: &str, shadow: &str| ShadowPackage {
            name: name.to_owned(),
            managed: PathBuf::from("/h/.pi/agent/packages").join(name),
            managed_version: None,
            extensions: PathBuf::from("/h/.pi/agent/extensions"),
            shadow: PathBuf::from("/h/.pi/agent/extensions").join(shadow),
            shadow_version: None,
        };
        let io = |path: &str| {
            CoreError::io(
                path,
                std::io::Error::new(std::io::ErrorKind::PermissionDenied, "denied"),
            )
        };
        let mut first = ShadowScan {
            found: vec![copy("pi-widgets", "pi-widgets")],
            errors: vec![io("/p/.pi/extensions")],
        };
        let mut second = ShadowScan {
            found: vec![
                copy("pi-widgets", "pi-widgets"),
                copy("pi-other", "pi-widgets"),
            ],
            errors: vec![io("/p/.pi/extensions"), io("/q/.pi/extensions")],
        };

        ShadowScan::fold([&mut first, &mut second]);

        assert_eq!(first.found, vec![copy("pi-widgets", "pi-widgets")]);
        assert_eq!(second.found, vec![copy("pi-other", "pi-widgets")]);
        let texts = |scan: &ShadowScan| -> Vec<String> {
            scan.errors.iter().map(ToString::to_string).collect()
        };
        assert_eq!(texts(&first), vec![io("/p/.pi/extensions").to_string()]);
        assert_eq!(texts(&second), vec![io("/q/.pi/extensions").to_string()]);
    }

    /// The four lines open on the key, name both copies with their
    /// versions, and name the entry to move and the directory to move it
    /// out of; every fragment from disk goes through the caller's scrub.
    #[test]
    fn the_lines_open_on_the_key_and_name_both_copies() {
        let shadow = ShadowPackage {
            name: "pi-widgets".to_owned(),
            managed: PathBuf::from("/h/.pi/agent/packages/pi-widgets"),
            managed_version: Some("2.0.0".to_owned()),
            extensions: PathBuf::from("/h/.pi/agent/extensions"),
            shadow: PathBuf::from("/h/.pi/agent/extensions/pi-widgets.ts"),
            shadow_version: None,
        };
        let lines = shadow.lines(|text| text.to_uppercase());
        assert_eq!(lines.key, format!("{KEY}=PI-WIDGETS"));
        assert_eq!(
            lines.managed,
            "managed copy /H/.PI/AGENT/PACKAGES/PI-WIDGETS (version 2.0.0)"
        );
        assert_eq!(
            lines.shadow,
            "shadow copy /H/.PI/AGENT/EXTENSIONS/PI-WIDGETS.TS (no version)"
        );
        assert_eq!(
            lines.remedy,
            "Pi loads both copies; move PI-WIDGETS.TS out of /H/.PI/AGENT/EXTENSIONS so only the managed copy runs"
        );
    }
}
