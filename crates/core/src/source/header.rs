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
    let Some(file) = header_file(kind, path) else {
        return Metadata::default();
    };
    if !sealed.is_file(&file) {
        return Metadata::default();
    }
    match sealed.read(&file) {
        Ok(bytes) => header_of(kind, &String::from_utf8_lossy(&bytes)),
        Err(_) => Metadata::default(),
    }
}

/// The catalogs one scope's declarations resolve to, opened once each.
///
/// A Library read asks for several packages' words at a time and most of
/// them come from one subscription: opening the catalog and parsing its
/// `kendex.toml` per package would pay for that once per row.
#[derive(Default)]
pub(crate) struct DeclaredHeaders {
    opened: std::collections::HashMap<String, Option<(SealedSource, super::SourceConfig)>>,
}

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
        // Keyed by what resolves the bytes — the source and the hold this
        // item declares on it — so two items of one source pinned to
        // different revisions never read each other's catalog.
        let key = format!("{}\u{1f}{}", decl.source, decl.rev.as_deref().unwrap_or(""));
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
        Some(read(sealed, kind, &path))
    }
}
