use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{copy_tree, remove_any};
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
pub(super) fn inside(base: &Path, relative: &str, name: &str) -> Result<PathBuf> {
    let path = Path::new(relative);
    if path.is_absolute()
        || path
            .components()
            .any(|part| part == std::path::Component::ParentDir)
    {
        return Err(CoreError::PiPackage {
            name: name.to_owned(),
            message: format!("`{relative}` points outside the package"),
        });
    }
    Ok(base.join(relative.trim_start_matches("./")))
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
    while dest.exists() {
        dest = dir.join(format!("{stamp}-{counter}-{base}"));
        counter += 1;
    }
    if std::fs::rename(path, &dest).is_ok() {
        return Ok(());
    }
    copy_tree(path, &dest)?;
    remove_any(path)
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
        assert!(inside(base, "../outside.js", "p").is_err());
        assert!(inside(base, "/etc/passwd", "p").is_err());
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
