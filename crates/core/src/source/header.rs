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
        ItemKind::Agent
        | ItemKind::Command
        | ItemKind::McpServer
        | ItemKind::Hook
        | ItemKind::OutputStyle => Some(path.to_path_buf()),
        ItemKind::Plugin => None,
    }
}

/// The header of one item, out of the text of its header file. A file that
/// will not parse describes itself with nothing rather than with a guess.
pub(crate) fn header_of(kind: ItemKind, text: &str) -> Metadata {
    match kind {
        ItemKind::Skill | ItemKind::Agent | ItemKind::Command | ItemKind::OutputStyle => {
            metadata::from_markdown(text)
        }
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
    Ok(try_text(sealed, kind, path)?
        .map(|text| header_of(kind, &text))
        .unwrap_or_default())
}

/// The text of one item's header file, for a caller that reads more out of
/// it than [`header_of`] does: `None` where the kind writes no header or
/// the file is not there, and an error where the seal refuses a file it
/// called a file, as in [`try_read`].
pub(crate) fn try_text(
    sealed: &SealedSource,
    kind: ItemKind,
    path: &Path,
) -> crate::error::Result<Option<String>> {
    let Some(file) = header_file(kind, path) else {
        return Ok(None);
    };
    if !sealed.is_file(&file) {
        return Ok(None);
    }
    let bytes = sealed.read(&file)?;
    Ok(Some(String::from_utf8_lossy(&bytes).into_owned()))
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

/// What one installation's own record says it came from.
///
/// A declaration is what a scope asks for now; this is what the
/// installation on disk actually is. They part company the moment
/// somebody edits the manifest, and every question about the bytes
/// already installed is answered from here.
pub(crate) struct InstalledFrom {
    /// The source name this installation was declared under.
    pub(crate) source: String,
    /// What that source resolved to when it was installed, verbatim as
    /// the record kept it. Compared whole, never folded.
    pub(crate) repo: String,
    /// The commit the bytes came out of, for a source that has one.
    pub(crate) commit: Option<String>,
}

/// Everything that decides which catalog a read opens: the scope, the
/// source name, what that name is required to resolve to, and the
/// revision the read is held at.
///
/// The scope belongs in the key because the name alone does not name a
/// catalog: `local` and `in-place` are per-scope roots, a `path =` is
/// read against the scope's root, and a repo source is whatever the
/// asking scope's own manifest declared. One string, two catalogs.
///
/// The provenance belongs in it because one name serves several
/// repositories over its life, and the revision because one repository
/// serves several commits: two installations of one name from different
/// repositories, and two of one repository at different commits, each
/// read their own.
type OpenedKey = (crate::model::Scope, String, Option<String>, Option<String>);

impl DeclaredHeaders {
    /// What one declared package's own source says about it, at the
    /// version this scope has installed. `None` where the declaration, the
    /// source or the item cannot be reached — an unreachable source
    /// describes a package with nothing, never with a borrowed or stale
    /// reading of a same-named package somewhere else.
    ///
    /// `installed` is what the installation's own record says it came
    /// from, and it outranks the current declaration in full — the source
    /// name, what that name has to resolve to, and the revision. A
    /// declaration is what the scope asks for now: its `source` can be
    /// re-pointed at another catalog, and a `rev` naming a branch or a
    /// tag is a selector the stale-source refresh re-resolves on its own.
    /// Read through either, this would answer for a package the scope
    /// has not installed. `None` where no record claims the
    /// installation; the declaration is all there is to go on then.
    ///
    /// A declaration that no longer reads where the record says this
    /// installation came from answers nothing rather than answering with
    /// the new catalog's words: a name two catalogs share is no evidence
    /// that either wrote these bytes.
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
        installed: Option<&InstalledFrom>,
    ) -> Option<Metadata> {
        let read_at = ReadAt::of(manifest, kind, name, installed)?;
        // Keyed by everything that decides the bytes — the scope, the
        // source name, what it must resolve to, and the revision — so no
        // two installations that differ in any of them read each other's
        // catalog.
        let key = (
            scope.clone(),
            read_at.source.clone(),
            read_at.repo.clone(),
            read_at.hold.clone(),
        );
        let opened = self
            .opened
            .entry(key)
            .or_insert_with(|| read_at.open(env, scope, manifest).ok());
        let (sealed, config) = opened.as_ref()?;
        let path = super::find_item(sealed, config, kind, name)?;
        // A kind that writes no header of its own has nothing to answer
        // with: a plugin's words belong to the registry that lists it, and
        // a blank reading here would stand in front of them.
        header_file(kind, &path)?;
        Some(read(sealed, kind, &path))
    }
}

/// The text of one installed package's header file, read where
/// [`DeclaredHeaders::of`] reads its words: the catalog and revision the
/// installation's record names, else the declaration's. The error is the
/// cause, worded for the person reading the package's record: a source
/// that is pending, switched off, gone from its path or re-pointed at
/// another repository, or an item no longer at that revision.
pub(crate) fn installed_text(
    env: &crate::env::Env,
    scope: &crate::model::Scope,
    manifest: &crate::manifest::Manifest,
    kind: ItemKind,
    name: &str,
    installed: Option<&InstalledFrom>,
) -> Result<String, String> {
    let read_at = ReadAt::of(manifest, kind, name, installed)
        .ok_or_else(|| format!("'{name}' is neither installed nor declared in this scope"))?;
    let (sealed, config) = read_at.open(env, scope, manifest)?;
    let path = super::find_item(&sealed, &config, kind, name).ok_or_else(|| {
        crate::error::CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: read_at.source.clone(),
        }
        .to_string()
    })?;
    try_text(&sealed, kind, &path)
        .map_err(|error| error.to_string())?
        .ok_or_else(|| format!("'{name}' has no header file in source '{}'", read_at.source))
}

/// Which catalog a read about one installation opens: the installation's
/// own record outranks the declaration in full, as
/// [`DeclaredHeaders::of`] sets out.
struct ReadAt {
    source: String,
    /// What the source must resolve to: the record's, where one claims the
    /// installation.
    repo: Option<String>,
    hold: Option<String>,
}

impl ReadAt {
    fn of(
        manifest: &crate::manifest::Manifest,
        kind: ItemKind,
        name: &str,
        installed: Option<&InstalledFrom>,
    ) -> Option<ReadAt> {
        Some(match installed {
            Some(installed) => ReadAt {
                source: installed.source.clone(),
                repo: Some(installed.repo.clone()),
                hold: installed.commit.clone(),
            },
            None => {
                let decl = manifest.declared(kind).get(name)?;
                ReadAt {
                    source: decl.source.clone(),
                    repo: None,
                    hold: decl.rev.clone(),
                }
            }
        })
    }

    /// The catalog, opened. Nothing here fetches: [`super::require_ready_at`]
    /// answers out of the cache a previous install filled and names why it
    /// cannot otherwise.
    fn open(
        &self,
        env: &crate::env::Env,
        scope: &crate::model::Scope,
        manifest: &crate::manifest::Manifest,
    ) -> Result<(SealedSource, super::SourceConfig), String> {
        let ready =
            super::require_ready_at(env, scope, &self.source, manifest, self.hold.as_deref())
                .map_err(|error| error.to_string())?;
        // The record names the catalog these bytes came out of. Where the
        // declaration now reads somewhere else, that is a different
        // catalog under one name and its words are about a different
        // package.
        if let Some(repo) = &self.repo
            && &ready.provenance != repo
        {
            return Err(format!(
                "source '{}' now reads {}, not {repo}, which this package was installed from",
                self.source, ready.provenance
            ));
        }
        let sealed = SealedSource::open(&ready.root).map_err(|error| error.to_string())?;
        let config = super::source_config_for(&sealed, &ready.provenance)
            .map_err(|error| error.to_string())?;
        Ok((sealed, config))
    }
}
