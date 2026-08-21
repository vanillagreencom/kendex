//! Which catalog a declaration reads from, and what it costs the pass when
//! that catalog cannot be read. Nothing here fails the scope: a source that
//! is switched off, not downloaded yet, gone from disk, or dressed up to
//! read outside itself costs the declarations that name it and nothing more.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{ItemDecl, Manifest};
use crate::model::Scope;
use crate::source::{self, SourceConfig, SourceState, source_config_for};
use crate::source_read::SealedSource;

use super::desired::DesiredState;

/// The source root, provenance, and commit to build an item from, or `None`
/// with the note that says why this declaration produces nothing this pass.
/// An item's own `rev` outranks the source's: a pinned declaration reads its
/// pinned commit's tree while the source resolution moves on.
pub(super) fn resolve_source(
    env: &Env,
    scope: &Scope,
    name: &str,
    decl: &ItemDecl,
    manifest: &Manifest,
    state: &mut DesiredState,
) -> Result<Option<(PathBuf, String, Option<String>)>> {
    let resolution = match decl.rev.as_deref() {
        // Pinned reads cache per (source, rev): two items pinned to the
        // same commit share one resolution, and neither disturbs the
        // source-level entry the lock records.
        Some(rev) => {
            let key = (decl.source.clone(), rev.to_owned());
            match state.pinned.get(&key) {
                Some(resolution) => resolution.clone(),
                None => {
                    let resolution =
                        source::resolve_at(env, scope, &decl.source, manifest, Some(rev))?;
                    state.pinned.insert(key, resolution.clone());
                    resolution
                }
            }
        }
        None => match state.sources.get(&decl.source) {
            Some(resolution) => resolution.clone(),
            None => {
                let resolution = source::resolve(env, scope, &decl.source, manifest)?;
                state
                    .sources
                    .insert(decl.source.clone(), resolution.clone());
                resolution
            }
        },
    };
    let notes = &mut state.notes;
    match resolution {
        SourceState::Ready(ready) => Ok(Some((ready.root, ready.provenance, ready.commit))),
        // A disabled source deactivates its installations in place; they stay
        // declared and are not drift.
        SourceState::Disabled { .. } => {
            notes.push(format!(
                "{name}: source '{}' disabled — inactive",
                decl.source
            ));
            Ok(None)
        }
        SourceState::Pending { repo, .. } => {
            notes.push(format!(
                "{name}: source '{}' ({repo}) not fetched yet — skipped",
                decl.source
            ));
            Ok(None)
        }
        SourceState::Missing { path, .. } => {
            notes.push(format!(
                "{name}: source '{}' missing at {} — skipped",
                decl.source,
                path.display()
            ));
            Ok(None)
        }
    }
}

/// The catalog behind one declaration: its sealed root — every read goes
/// through one, so a hostile catalog cannot smuggle host files in — and its
/// layout tables. `None` with the note that says why this declaration
/// produces nothing this pass: a root that cannot be opened is skipped like
/// a missing one, and a registry or config dressed up to read outside the
/// catalog costs this declaration and nothing else.
pub(super) fn read_catalog(
    root: &Path,
    provenance: &str,
    name: &str,
    source: &str,
    state: &mut DesiredState,
) -> Result<Option<(SealedSource, SourceConfig)>> {
    let sealed = match SealedSource::open(root) {
        Ok(sealed) => sealed,
        Err(problem) => {
            state.notes.push(crate::names::shown(&format!(
                "{name}: source '{source}' unreadable ({problem}) — skipped"
            )));
            return Ok(None);
        }
    };
    match source_config_for(&sealed, provenance) {
        Ok(config) => Ok(Some((sealed, config))),
        Err(CoreError::SourceEscape { path, reason }) => {
            state.notes.push(crate::names::shown(&format!(
                "{name}: unreadable — refused catalog read: {reason} ({})",
                path.display()
            )));
            Ok(None)
        }
        Err(other) => Err(other),
    }
}

/// What this item's publisher already settled about it, read out of the
/// source this pass fetched.
///
/// `reviews` caches each source root's parsed reviews file for the pass —
/// keyed by the root and not by the source name, because one source can
/// resolve to several roots in one pass when items pin different revisions,
/// and a record read from one commit must never answer for another.
///
/// Every way this can settle nothing is said out loud. Failing closed is
/// right; failing closed in silence leaves an installer looking at a
/// package held back over findings its publisher reviewed, unable to tell
/// that from a publisher who reviewed nothing. Catalog-derived text is
/// escaped on the way in: a parse error quotes the offending line, and a
/// line of a downloaded file is not something to hand a terminal.
#[allow(clippy::too_many_arguments)]
pub(super) fn published_review(
    sealed: &SealedSource,
    source_name: &str,
    provenance: &str,
    kind: crate::model::ItemKind,
    name: &str,
    item_path: &Path,
    reviews: &mut std::collections::BTreeMap<
        PathBuf,
        std::collections::BTreeMap<String, crate::quality::reviews::SafetyReview>,
    >,
    state: &mut DesiredState,
) -> Result<Option<crate::quality::author::AuthorReview>> {
    // A hook is scored from the script this plan writes and audited from
    // the shared settings file its registration lands in — two readings of
    // different bytes, by design (see `engine::review_hash`). A record can
    // bind to one or the other and never both, so honouring one at the gate
    // would install an item the very next audit re-opens. Refused where it
    // is read, so the plan, the lock and the audit all answer alike.
    if kind == crate::model::ItemKind::Hook {
        return Ok(None);
    }
    let mut unreadable = None;
    let parsed = reviews
        .entry(sealed.root().to_path_buf())
        .or_insert_with(|| match crate::check_catalog::dismissals::load(sealed) {
            Ok(parsed) => parsed,
            Err(error) => {
                unreadable = Some(crate::names::shown(&error.to_string()));
                Default::default()
            }
        });
    let read = crate::quality::author::for_item(parsed, sealed, kind, name, item_path, provenance);
    if let Some(problem) = unreadable {
        state.notes.push(format!(
            "source '{source_name}': {} could not be read, so nothing it reviewed counts as reviewed — {problem}",
            crate::check_catalog::dismissals::REVIEWS_FILE
        ));
    }
    if !read.refused.is_empty() {
        state.notes.push(format!(
            "{} {name}: {} of the {} record(s) {source_name} carries for it settle nothing here — the claim is not one an author can make",
            kind.name(),
            read.refused.len(),
            crate::check_catalog::dismissals::REVIEWS_FILE
        ));
    }
    if let Some(why) = read.stale {
        state.notes.push(crate::names::shown(&format!(
            "{} {name}: {source_name} reviewed it, but that review no longer applies — {why}",
            kind.name()
        )));
    }
    Ok(read.review)
}
