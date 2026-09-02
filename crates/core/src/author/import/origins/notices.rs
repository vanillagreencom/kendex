//! The licence evidence that travels with copied bytes: the root-level
//! licence and attribution files of the catalog an origin came from. The
//! stems it collects are the function's own to spell, since the code is
//! the only complete list.
//!
//! Its own file because it answers a different question from the rest of
//! `origins`: not where the bytes live, but what has to be copied beside
//! them for the copy to be honest.

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::source_read::SealedSource;

use super::scope_manifest;

/// Root-level licence and attribution files of one catalog — the evidence
/// that must travel with copied bytes.
///
/// Every read the source refuses is the refusal: the open, the listing,
/// each entry's own nature, and each file's bytes. Other listings in this
/// crate answer an unreadable directory by drawing no rows, which costs a
/// surface some rows; here it would copy somebody's bytes with their
/// licence left behind and say nothing. A source that is not resolvable at
/// all is the one answer that is not a refusal: it has no root to carry
/// evidence from, and the import's own provenance rules judge that.
pub(super) fn notice_files(
    env: &Env,
    scope: &Scope,
    source: &str,
) -> Result<Vec<(String, Vec<u8>)>> {
    let manifest = scope_manifest(env, scope);
    let Ok(crate::source::SourceState::Ready(resolved)) =
        crate::source::resolve(env, scope, source, &manifest)
    else {
        return Ok(Vec::new());
    };
    // Carried, not swallowed, though no deterministic case drives it:
    // `resolve` hands back `Ready` only after finding the root a
    // directory, so what is left here is the root going away or losing its
    // permissions between that answer and this open. A refusal is the
    // right default for a read whose absence would publish a package
    // without its licence, whether or not a fixture can stage it.
    let sealed = SealedSource::open(&resolved.root)?;
    let mut notices = Vec::new();
    for entry in sealed.entries(&resolved.root)? {
        // The stem is read off the lossy spelling, so bytes no UTF-8
        // decodes cannot hide a licence behind an ASCII name: on Linux a
        // filename is bytes, and `LICENSE.<invalid>` has the stem this
        // collects.
        let Some(raw) = entry.file_name() else {
            continue;
        };
        let shown = raw.to_string_lossy();
        let stem = shown
            .split('.')
            .next()
            .unwrap_or(&shown)
            .to_ascii_uppercase();
        if !matches!(stem.as_str(), "LICENSE" | "LICENCE" | "NOTICE" | "COPYING") {
            continue;
        }
        // A name the copy could not reproduce is the refusal, not a skip:
        // the notice is written under this name at the destination, and
        // there is no name to write it under.
        let Some(name) = raw.to_str() else {
            return Err(CoreError::SourceEscape {
                path: entry.clone(),
                reason: "a licence file's name is not valid UTF-8, so the copy cannot carry it"
                    .to_owned(),
            });
        };
        // Asked through the sealed reader, which refuses a link rather
        // than following it: read as a boolean, a symlinked LICENSE is
        // skipped as though it were no file at all, and the copy goes out
        // without the notice it was standing for.
        if sealed.entry(&entry)?.is_some_and(|meta| meta.is_file()) {
            notices.push((name.to_owned(), sealed.read(&entry)?));
        }
    }
    notices.sort();
    Ok(notices)
}
