//! One file of a sealed item, read for preview — shared by an installed
//! package's page and a catalog's offered package.

use std::path::Path;

use crate::engine::ItemSource;
use crate::error::{CoreError, Result};
use crate::source_read::SealedSource;

/// The validated read behind [`package_file`], for any sealed item — an
/// installed package's or a catalog's offered one.
pub(crate) fn item_file(sealed: &SealedSource, item_path: &Path, rel: &str) -> Result<ItemSource> {
    let clean = Path::new(rel);
    let traversal = clean.is_absolute()
        || clean
            .components()
            .any(|c| !matches!(c, std::path::Component::Normal(_)));
    if rel.is_empty() || traversal {
        return Err(CoreError::SourceEscape {
            path: clean.to_path_buf(),
            reason: "a package file is named by a plain relative path".to_owned(),
        });
    }
    let target = if sealed.is_dir(item_path) {
        item_path.join(clean)
    } else {
        item_path.to_path_buf()
    };
    let bytes = sealed.read(&target)?;
    Ok(super::detail::capped(&target, bytes))
}
