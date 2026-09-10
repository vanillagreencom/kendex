//! What one catalog item says about itself, read from wherever its kind
//! keeps it.
//!
//! One reader for every surface that shows a package's own words: the
//! Packages table, the available-package page, the directory index that
//! `kendex index` emits, and the Library row of a package installed from a
//! catalog. A second spelling of "where does this kind write its header"
//! is how a marketplace row and the page it opens come to describe one
//! package version differently.

use std::path::{Path, PathBuf};

use crate::model::ItemKind;
use crate::scan::metadata::{self, Metadata};
use crate::source_read::SealedSource;

/// The file one kind writes its header in, under the item path
/// [`super::find_item`] resolves. `None` for a kind that writes none of its
/// own: a plugin's words belong to the registry that lists it, not to a
/// file inside it.
pub(crate) fn header_file(kind: ItemKind, path: &Path) -> Option<PathBuf> {
    match kind {
        ItemKind::Skill => Some(path.join("SKILL.md")),
        // npm's own manifest is the declaration home a Pi extension's
        // format already gives its author.
        ItemKind::PiExtension => Some(path.join("package.json")),
        ItemKind::Agent | ItemKind::Command | ItemKind::McpServer | ItemKind::Hook => {
            Some(path.to_path_buf())
        }
        ItemKind::Plugin => None,
    }
}

/// The header of one item, out of the text of its header file. A file that
/// will not parse describes itself with nothing rather than with a guess.
pub(crate) fn header_of(kind: ItemKind, text: &str) -> Metadata {
    match kind {
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command => metadata::from_markdown(text),
        ItemKind::McpServer => metadata::from_toml(text),
        ItemKind::Hook => metadata::from_hook_script(text),
        ItemKind::PiExtension => metadata::from_package_json(text),
        ItemKind::Plugin => Metadata::default(),
    }
}

/// The header of one item inside a sealed catalog, at the item path
/// [`super::find_item`] resolved. A file that is not there, or that the
/// seal will not hand over, describes itself with nothing — the same
/// answer an item whose author wrote no header gives, and the one every
/// blank-state rule downstream is written against.
pub(crate) fn read(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Metadata {
    try_read(sealed, kind, path).unwrap_or_default()
}

/// [`read`] for a caller that publishes what it reads and must not
/// publish a row about a file it could not open. A header that is not
/// there is still nothing rather than an error — that is the state an
/// author who wrote none leaves — but a seal that refuses a file it just
/// called a file is a failure of the read, and `kendex index` feeds the
/// community directory, where a silently summary-less row is harder to
/// notice than a run that stopped.
pub(crate) fn try_read(
    sealed: &SealedSource,
    kind: ItemKind,
    path: &Path,
) -> crate::error::Result<Metadata> {
    let Some(file) = header_file(kind, path) else {
        return Ok(Metadata::default());
    };
    if !sealed.is_file(&file) {
        return Ok(Metadata::default());
    }
    let bytes = sealed.read(&file)?;
    Ok(header_of(kind, &String::from_utf8_lossy(&bytes)))
}

/// The catalogs one scope's declarations resolve to, opened once each.
///
/// A Library read asks for several packages' words at a time and most of
/// them come from one subscription: opening the catalog and parsing its
/// `kendex.toml` per package would pay for that once per row.
#[derive(Default)]
pub(crate) struct DeclaredHeaders {
    opened: std::collections::HashMap<OpenedKey, Option<(SealedSource, super::SourceConfig)>>,
}

/// What decides which catalog a declaration opens: the scope whose
/// manifest declared the source, the name it declared it under, and the
/// hold the item takes on it.
///
/// The scope belongs in the key because the name alone does not name a
/// catalog: `local` and `in-place` are per-scope roots, a `path =` is
/// read against the scope's root, and a repo source is whatever the
/// asking scope's own manifest declared. One string, two catalogs.
type OpenedKey = (crate::model::Scope, String, Option<String>);

impl DeclaredHeaders {
    /// What one declared package's own source says about it, at the
    /// version this scope has installed. `None` where the declaration, the
    /// source or the item cannot be reached — an unreachable source
    /// describes a package with nothing, never with a borrowed or stale
    /// reading of a same-named package somewhere else.
    ///
    /// Nothing here fetches. [`super::resolve_at`] answers out of the cache
    /// a previous install filled and reports the source pending otherwise,
    /// so reading a row never costs a network call.
    pub(crate) fn of(
        &mut self,
        env: &crate::env::Env,
        scope: &crate::model::Scope,
        manifest: &crate::manifest::Manifest,
        kind: ItemKind,
        name: &str,
    ) -> Option<Metadata> {
        let decl = manifest.declared(kind).get(name)?;
        // Keyed by everything that resolves the bytes — the scope, the
        // source and the hold this item declares on it — so two items of
        // one source pinned to different revisions, and two scopes that
        // declared one name differently, never read each other's catalog.
        let key = (scope.clone(), decl.source.clone(), decl.rev.clone());
        let opened = self.opened.entry(key).or_insert_with(|| {
            let state =
                super::resolve_at(env, scope, &decl.source, manifest, decl.rev.as_deref()).ok()?;
            let super::SourceState::Ready(ready) = state else {
                return None;
            };
            let sealed = SealedSource::open(&ready.root).ok()?;
            let config = super::source_config(&sealed, super::repo_leaf(&ready.provenance)).ok()?;
            Some((sealed, config))
        });
        let (sealed, config) = opened.as_ref()?;
        let path = super::find_item(sealed, config, kind, name)?;
        // A kind that writes no header of its own has nothing to answer
        // with: a plugin's words belong to the registry that lists it, and
        // a blank reading here would stand in front of them.
        header_file(kind, &path)?;
        Some(read(sealed, kind, &path))
    }
}
