//! Package comparisons shared by reports and carrier installation.

use std::path::Path;

use crate::error::{CoreError, Result};

/// Installed bytes compared with the bytes a caller expects.
#[derive(Debug, PartialEq, Eq)]
pub enum PackageState {
    /// The package directory is absent.
    Missing,
    /// The directory exists but its copied files differ.
    Different,
    /// The copied files match, with the hash used for provenance.
    Current { hash: String },
}

/// Compare installed package files without reading or materializing a source.
pub fn installed_state(root: &Path, name: &str, expected: Option<&str>) -> Result<PackageState> {
    Ok(match super::installed_hash(root, name)? {
        None => PackageState::Missing,
        Some(hash) if Some(hash.as_str()) == expected => PackageState::Current { hash },
        Some(_) => PackageState::Different,
    })
}

/// Compare the installed package against the resolved declaration.
pub fn declared_state(
    root: &Path,
    name: &str,
    package: &super::DeclaredPackage,
) -> Result<PackageState> {
    let expected =
        super::package_hash(&package.source_dir)?.ok_or_else(|| CoreError::PiPackage {
            name: name.to_owned(),
            message: "declared package directory is missing".to_owned(),
        })?;
    installed_state(root, name, Some(&expected))
}
