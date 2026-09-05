//! Package comparisons shared by reports and carrier installation.

use std::path::Path;

use crate::error::{CoreError, Result};

/// Installed bytes compared with the bytes a caller expects.
#[derive(Debug, PartialEq, Eq)]
pub enum PackageState {
    /// The package directory is absent.
    Missing,
    /// The files or required installation record do not match.
    Different,
    /// The copied files match, with the hash used for provenance.
    Current { hash: String },
}

/// Evidence a caller needs before accepting matching package bytes.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RecordBasis {
    /// Ordinary reports and refresh require a matching completed install.
    Recorded,
    /// The installer completed, or explicit recovery accepts matching renders.
    MatchedBytes,
}

pub(super) fn matches_record(entry: &crate::lock::LockEntry, name: &str, hash: &str) -> bool {
    entry.kind == crate::model::ItemKind::PiExtension
        && entry.harness == crate::model::HarnessId::Pi
        && entry.name == name
        && entry.source_hash == hash
        && entry.rendered_hash.as_deref() == Some(hash)
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
    existing: Option<&crate::lock::LockEntry>,
    basis: RecordBasis,
) -> Result<PackageState> {
    let expected =
        super::package_hash(&package.source_dir)?.ok_or_else(|| CoreError::PiPackage {
            name: name.to_owned(),
            message: "declared package directory is missing".to_owned(),
        })?;
    let state = installed_state(root, name, Some(&expected))?;
    if let PackageState::Current { hash } = &state
        && basis == RecordBasis::Recorded
        && !existing.is_some_and(|entry| matches_record(entry, name, hash))
    {
        return Ok(PackageState::Different);
    }
    Ok(state)
}
