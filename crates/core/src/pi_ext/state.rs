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
    /// The copied files match, with the source and rendered identities the
    /// lock persists in their separate fields.
    Current {
        source_hash: String,
        rendered_hash: String,
    },
}

/// Evidence a caller needs before accepting matching package bytes.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum RecordBasis {
    /// Ordinary reports and refresh require a matching completed install.
    Recorded,
    /// The installer completed, or explicit recovery accepts matching renders.
    MatchedBytes,
}

pub(super) fn matches_record(
    entry: &crate::lock::LockEntry,
    name: &str,
    source_hash: &str,
    rendered_hash: &str,
) -> bool {
    entry.kind == crate::model::ItemKind::PiExtension
        && entry.harness == crate::model::HarnessId::Pi
        && entry.name == name
        && entry.source_hash == source_hash
        && entry.rendered_hash.as_deref() == Some(rendered_hash)
}

/// Compare installed package files without reading or materializing a source.
pub fn installed_state(root: &Path, name: &str, expected: Option<&str>) -> Result<PackageState> {
    Ok(match super::installed_hash(root, name)? {
        None => PackageState::Missing,
        Some(hash) if Some(hash.as_str()) == expected => PackageState::Current {
            source_hash: hash.clone(),
            rendered_hash: hash,
        },
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
    let destination = super::package_path(root, name)?;
    let source = super::files::package_identity(&package.source_dir, false)?.ok_or_else(|| {
        CoreError::PiPackage {
            name: name.to_owned(),
            message: "declared package directory is missing".to_owned(),
        }
    })?;
    let rendered = super::files::package_rendered_identity(&package.source_dir, &destination)?
        .ok_or_else(|| CoreError::PiPackage {
            name: name.to_owned(),
            message: "declared package directory is missing".to_owned(),
        })?;
    let Some(installed) = super::files::package_identity(&destination, true)? else {
        return Ok(PackageState::Missing);
    };
    if installed.exact() != source.exact() && !installed.matches(rendered.persisted()) {
        return Ok(PackageState::Different);
    }
    let source_hash = source.persisted().to_owned();
    let rendered_hash = rendered.persisted().to_owned();
    let state = PackageState::Current {
        source_hash: source_hash.clone(),
        rendered_hash: rendered_hash.clone(),
    };
    if let PackageState::Current { .. } = &state {
        if !super::settings::references_package(&super::settings_path(root), name)? {
            return Ok(PackageState::Different);
        }
        if basis == RecordBasis::Recorded
            && !existing
                .is_some_and(|entry| matches_record(entry, name, &source_hash, &rendered_hash))
        {
            return Ok(PackageState::Different);
        }
    }
    Ok(state)
}
