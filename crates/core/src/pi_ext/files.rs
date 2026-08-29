use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::move_any;
use crate::hash::hash_files;

/// Never copied or hashed: dependency trees and build output are recreated
/// at the destination rather than carried across.
const SKIPPED: &[&str] = &[
    "node_modules",
    ".git",
    ".turbo",
    ".next",
    ".cache",
    "build",
    "out",
    "coverage",
    ".pi",
    ".test-output",
];

/// A missing directory is empty, not an error — most scopes have no pi
/// content at all.
pub(super) fn read_dir(path: &Path) -> Result<Vec<std::fs::DirEntry>> {
    match std::fs::read_dir(path) {
        Ok(entries) => Ok(entries.flatten().collect()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
        Err(e) => Err(CoreError::io(path, e)),
    }
}

/// Hash a package directory as it would be copied, so an installed copy with
/// a built `node_modules` still matches the source it came from. Reads go
/// through the sealed walk — package sources are catalog content.
pub fn package_hash(package_dir: &Path) -> Result<Option<String>> {
    if !package_dir.is_dir() {
        return Ok(None);
    }
    let sealed = crate::source_read::SealedSource::open(package_dir)?;
    let files = sealed.collect_tree(sealed.root(), SKIPPED)?;
    Ok(Some(hash_files(&files)))
}

pub(super) fn copy_package(from: &Path, to: &Path) -> Result<()> {
    std::fs::create_dir_all(to).map_err(|e| CoreError::io(to, e))?;
    let sealed = crate::source_read::SealedSource::open(from)?;
    for (rel, bytes) in sealed.collect_tree(sealed.root(), SKIPPED)? {
        let dest = to.join(&rel);
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
        }
        std::fs::write(&dest, bytes).map_err(|e| CoreError::io(&dest, e))?;
        // Executable bits must survive the copy — package bin scripts run.
        let source = sealed.root().join(&rel);
        if let Ok(meta) = std::fs::metadata(&source) {
            let _ = std::fs::set_permissions(&dest, meta.permissions());
        }
    }
    Ok(())
}

/// `<scope>/packages/<name>` for a name npm would accept — anything that
/// could climb out of the packages dir is refused.
pub(super) fn package_path(scope_root: &Path, name: &str) -> Result<PathBuf> {
    let parts: Vec<&str> = name.split('/').collect();
    let shaped = match parts.as_slice() {
        [plain] => !plain.starts_with('@'),
        [scope, _] => scope.starts_with('@'),
        _ => false,
    };
    let usable = parts
        .iter()
        .all(|part| !part.is_empty() && *part != "." && *part != ".." && !part.contains('\\'));
    if !shaped || !usable {
        return Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: "not a usable npm package name".to_owned(),
        });
    }
    Ok(parts
        .iter()
        .fold(super::packages_dir(scope_root), |path, part| {
            path.join(part)
        }))
}

/// Resolve a package-relative path from `package.json`, refusing one that
/// points outside the package.
///
/// The declared string is judged on its own shape, not on what the running
/// platform makes of it, so one `package.json` is refused identically
/// wherever it installs. `Path::is_absolute` cannot do that: on Windows
/// `/etc/passwd` is not absolute, Rust wanting a drive or a UNC prefix
/// first, and `Path::join` drops the base for it anyway. So a leading `/`
/// is refused everywhere, and so are the two characters that spell the
/// Windows escapes: `\`, which is a separator there and hides `..\..` from
/// `Component::ParentDir` when the string is parsed here, and `:`, which
/// opens a drive, a device prefix or an alternate data stream. The result
/// is then built from the segments checked here rather than by joining the
/// declared string, so nothing unexamined reaches the filesystem.
pub(super) fn inside(base: &Path, relative: &str, name: &str) -> Result<PathBuf> {
    let refuse = || CoreError::PiPackage {
        name: name.to_owned(),
        message: format!("`{relative}` does not name a path inside the package"),
    };
    if relative.starts_with('/') || relative.contains('\\') || relative.contains(':') {
        return Err(refuse());
    }
    let mut path = base.to_path_buf();
    let mut named = false;
    for part in relative.split('/') {
        if part.is_empty() || part == "." {
            continue;
        }
        if part == ".." {
            return Err(refuse());
        }
        path.push(part);
        named = true;
    }
    // Nothing but separators and `.` names the package directory itself,
    // which is not a file a package can declare.
    if !named {
        return Err(refuse());
    }
    Ok(path)
}

/// Removal never deletes: the replaced or uninstalled copy moves to the
/// trash, dependency tree and all.
pub(super) fn trash(env: &Env, path: &Path) -> Result<()> {
    let dir = env.trash_dir();
    std::fs::create_dir_all(&dir).map_err(|e| CoreError::io(&dir, e))?;
    let base = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "pi-package".to_owned());
    let stamp = crate::clock::timestamp().replace(':', "-");
    let mut dest = dir.join(format!("{stamp}-{base}"));
    let mut counter = 1;
    // A link, not what it points at: a name held by a link whose target is
    // gone reads as free, and the move onto it then fails.
    while dest.exists() || dest.is_symlink() {
        dest = dir.join(format!("{stamp}-{counter}-{base}"));
        counter += 1;
    }
    move_any(path, &dest)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn package_paths_nest_scopes_and_refuse_escapes() {
        let scope = Path::new("/s");
        assert_eq!(
            package_path(scope, "@vg/pi-hooks").unwrap(),
            PathBuf::from("/s/packages/@vg/pi-hooks")
        );
        assert_eq!(
            package_path(scope, "pi-hooks").unwrap(),
            PathBuf::from("/s/packages/pi-hooks")
        );
        for bad in ["", "..", "../evil", "/abs", "a/b/c", "@vg", "vg/pi", "a\\b"] {
            assert!(package_path(scope, bad).is_err(), "{bad} should be refused");
        }
    }

    #[test]
    fn package_relative_paths_stay_inside() {
        let base = Path::new("/pkg");
        assert_eq!(
            inside(base, "./cli.js", "p").unwrap(),
            PathBuf::from("/pkg/cli.js")
        );
        assert_eq!(
            inside(base, "dist/index.js", "p").unwrap(),
            PathBuf::from("/pkg/dist/index.js")
        );
        // `.` and doubled separators are spelling, not an escape: a run of
        // separators collapses, so both of these name the same file under the
        // package and resolve there. The second is where the old code judged
        // one string and joined another — trimming `./` off the front left a
        // rooted path that `join` then dropped the base for, landing it on
        // `/dist/sub/index.js` on Unix as much as on Windows.
        for spelling in ["dist/./sub//index.js", ".//dist/sub/index.js"] {
            assert_eq!(
                inside(base, spelling, "p").unwrap(),
                PathBuf::from("/pkg/dist/sub/index.js"),
                "{spelling:?} names a file inside the package"
            );
        }
        assert!(inside(base, "../outside.js", "p").is_err());
        assert!(inside(base, "/etc/passwd", "p").is_err());
    }

    /// Every one of these is an escape on some platform, so `inside` refuses
    /// it on all of them: the rule reads the declared string, and a package
    /// author's `package.json` cannot mean one thing on Linux and another on
    /// Windows. Each case is refused on the platform running this test, which
    /// is what makes the property testable off Windows at all.
    #[test]
    fn escape_spellings_are_refused_on_every_platform() {
        let base = Path::new("/pkg");
        for spelling in [
            // Rooted. `is_absolute` says false on Windows, `join` drops the
            // base anyway.
            "/etc/passwd",
            // Drive-absolute and drive-relative. Neither is absolute to Rust
            // on Unix, and `C:foo` resolves against the drive's own cwd.
            "C:\\Windows\\System32\\drivers\\etc\\hosts",
            "C:/Windows/System32",
            "C:evil",
            // UNC share and device namespace.
            "\\\\server\\share\\evil",
            "\\\\?\\C:\\evil",
            // Backslash traversal: `Component::ParentDir` never sees it when
            // the string is parsed on Unix.
            "..\\..\\evil",
            "dist\\..\\..\\evil",
            // Alternate data stream: a second, hidden write target on the
            // same name.
            "cli.js:stream",
            // Forward-slash traversal, in and past the middle of a path.
            "../outside.js",
            "dist/../../outside.js",
            // Names nothing at all — the package directory or the bin
            // directory itself, which a caller would then unlink.
            "",
            ".",
            "./",
            "/",
        ] {
            assert!(
                inside(base, spelling, "p").is_err(),
                "{spelling:?} should be refused"
            );
        }
    }

    /// A name a dangling link holds is a name that is taken, and `exists`
    /// says it is free. What the move onto it then does depends on the
    /// shape: a directory is refused (ENOTDIR from rename, then EEXIST
    /// from the copy) and the uninstall aborts, while anything else is
    /// renamed straight over the link and the trash loses what it held.
    /// The guard is for both. Both seconds the call can land in are
    /// seeded, so the clock cannot decide which name it reaches for.
    #[cfg(unix)]
    #[test]
    fn a_trash_name_a_dangling_link_holds_is_not_taken() {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), crate::env::FakeOs::Linux);
        let dir = env.trash_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let now = crate::clock::unix_now();
        let held: Vec<PathBuf> = [now, now + 1]
            .iter()
            .map(|secs| {
                let stamp = crate::clock::iso_from_unix(*secs).replace(':', "-");
                dir.join(format!("{stamp}-pi-hooks"))
            })
            .collect();
        for name in &held {
            std::os::unix::fs::symlink(tmp.path().join("gone"), name).unwrap();
        }
        let package = tmp.path().join("pi-hooks");
        std::fs::create_dir_all(&package).unwrap();
        std::fs::write(package.join("package.json"), "{}").unwrap();

        trash(&env, &package).unwrap();

        assert!(!package.exists());
        for name in &held {
            assert!(name.is_symlink(), "{} was taken", name.display());
        }
        let landed: Vec<PathBuf> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .map(|entry| entry.path())
            .filter(|path| path.join("package.json").is_file())
            .collect();
        assert_eq!(landed.len(), 1, "{landed:?}");
        // Somewhere other than the two names that were already taken —
        // which counter it got is the clock's business, not this test's.
        assert!(!held.contains(&landed[0]), "{:?}", landed[0]);
    }

    /// The installed copy replaced by a link whose target is gone, with the
    /// trash on another mount so the move is made by hand rather than by
    /// rename. Read through, the copy fails with the target's ENOENT and
    /// the uninstall aborts on it. /dev/shm is the second mount; a machine
    /// that does not have it as one has nothing to prove here.
    #[cfg(target_os = "linux")]
    #[test]
    fn a_copy_that_is_a_link_crosses_a_mount_into_the_trash() {
        use std::os::unix::fs::MetadataExt as _;
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), crate::env::FakeOs::Linux);
        let Ok(elsewhere) = tempfile::tempdir_in("/dev/shm") else {
            return;
        };
        let (Ok(here), Ok(there)) = (
            std::fs::metadata(tmp.path()).map(|m| m.dev()),
            std::fs::metadata(elsewhere.path()).map(|m| m.dev()),
        ) else {
            return;
        };
        if here == there {
            return;
        }
        let installed = elsewhere.path().join("pi-hooks");
        let gone = elsewhere.path().join("gone");
        std::os::unix::fs::symlink(&gone, &installed).unwrap();

        trash(&env, &installed).unwrap();

        assert!(!installed.is_symlink());
        let held = std::fs::read_dir(env.trash_dir())
            .unwrap()
            .flatten()
            .next()
            .unwrap()
            .path();
        assert_eq!(std::fs::read_link(held).unwrap(), gone);
    }

    #[test]
    fn hashing_and_copying_agree_on_what_to_skip() {
        let tmp = tempfile::tempdir().unwrap();
        let source = tmp.path().join("src");
        std::fs::create_dir_all(source.join("dist")).unwrap();
        std::fs::create_dir_all(source.join("node_modules/dep")).unwrap();
        std::fs::write(source.join("dist/index.js"), "one").unwrap();
        std::fs::write(source.join("node_modules/dep/index.js"), "junk").unwrap();

        let dest = tmp.path().join("dest");
        copy_package(&source, &dest).unwrap();
        assert!(dest.join("dist/index.js").is_file());
        assert!(!dest.join("node_modules").exists());
        assert_eq!(package_hash(&source).unwrap(), package_hash(&dest).unwrap());

        std::fs::write(source.join("dist/index.js"), "two").unwrap();
        assert_ne!(package_hash(&source).unwrap(), package_hash(&dest).unwrap());
        assert_eq!(package_hash(&tmp.path().join("gone")).unwrap(), None);
    }
}
