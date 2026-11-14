//! The one reading of relative links in stored skill bytes.
//!
//! Every stored skill tree's links mean what they reach from the one
//! position its store fixes: a path catalog's item directory, the scope's
//! shared tree for scope-owned content tagged `links = "shared-tree"`, a
//! destination catalog's item directory for an import. An installed or
//! unmanaged copy reads them where it stands ([`observed`]). Untagged
//! scope-owned content carries its bytes as each place it was delivered to
//! ([`delivered`]) reads them, and a fetched catalog's bytes are the
//! publisher's; neither is converted where it is stored.
//!
//! What a stored tree's links mean is decided here: the renderer and every
//! writer that converts stored skill bytes ask [`declared`] or
//! [`as_delivered`] rather than reading the source name and tag
//! themselves. Each converts once, at the move, with [`convert`] or
//! [`agreed`], and compares trees in the one form [`comparable_tree`]
//! gives. Every [`Origin`] takes its position from this owner: observed
//! scope positions use [`observed`], recorded positions use [`delivered`],
//! and stored positions retain their declared catalog or template reading.

use std::path::{Path, PathBuf};

use super::{Files, SKILL_FILE};
use crate::engine::ItemWarning;
use crate::env::Env;
use crate::manifest::{INPLACE_SOURCE_NAME, ItemDecl, LOCAL_SOURCE_NAME, Manifest, SkillLinks};
use crate::model::{ItemKind, Scope};
use crate::render::agent::BodyPaths;
use crate::source_read::SealedSource;

/// A directory links are read from, and the bound a target must stay
/// inside to be represented from it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Position {
    pub(crate) directory: PathBuf,
    pub(crate) bound: PathBuf,
}

/// What a stored tree's links mean.
#[derive(Clone)]
pub(crate) enum Reading {
    /// Links mean what they reach from `position.directory`.
    Fixed {
        position: Position,
        siblings: Siblings,
    },
    /// Untagged scope-owned content: each position reads the bytes as it
    /// was delivered them. Never converted or judged.
    AsDelivered,
    /// A fetched catalog: the bytes are the publisher's contract.
    Opaque,
}

/// What may stand beside a reading position and move with its own tree, so
/// a link into it keeps its bytes.
#[derive(Clone)]
pub(crate) enum Siblings {
    /// A harness skills directory or the shared tree: every subdirectory
    /// is a skill tree.
    SkillsDirectory,
    /// An authored catalog: a directory the catalog gives a `SKILL.md`.
    Catalog(SealedSource),
    /// A hand-made folder: nothing beside it is known to be a skill.
    Unknown,
}

/// One position a writer holds the tree at, with the bytes it holds there.
pub(crate) struct Origin {
    directory: PathBuf,
    /// Its regular files.
    pub(crate) files: Files,
    pub(crate) siblings: Siblings,
    /// Its files that are links, which a move carries as they are.
    pub(crate) link_files: Vec<LinkFile>,
}

impl Origin {
    pub(crate) fn new(
        position: Position,
        files: Files,
        siblings: Siblings,
        link_files: Vec<LinkFile>,
    ) -> Self {
        Self {
            directory: position.directory,
            files,
            siblings,
            link_files,
        }
    }

    pub(crate) fn directory(&self) -> &Path {
        &self.directory
    }
}

/// A file inside a tree that is a symbolic link: `target` is what it
/// holds, never followed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct LinkFile {
    pub(crate) file: PathBuf,
    pub(crate) target: PathBuf,
}

/// What a link file reaches from where it stands, resolved without
/// following anything: a place inside its own tree by its path there, any
/// other place by its whole path.
#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Reaches {
    Inside(PathBuf),
    Outside(PathBuf),
    /// A target whose `..` climbs past the root.
    Nowhere(PathBuf),
}

/// A link a conversion kept as written because its target does not
/// resolve, or falls outside the destination's bound. Its bytes make no
/// claim to reach the target they reached before.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct KeptLink {
    pub(crate) file: PathBuf,
    pub(crate) target: String,
}

/// The outcome of interpreting every origin position into one destination.
pub(crate) enum Converted {
    /// Every origin gave the same link meanings; `files` are the first
    /// origin's converted bytes.
    Agreed { files: Files, kept: Vec<KeptLink> },
    /// The first position, and the first one whose tree means something
    /// else there.
    Disagree { positions: [PathBuf; 2] },
}

/// The bound a scope's renders and its own stores share: the project root,
/// or the volume holding home.
pub(crate) fn scope_bound(env: &Env, scope: &Scope) -> PathBuf {
    match scope {
        Scope::Project { root } => root.clone(),
        Scope::Global => volume(&env.home),
    }
}

fn volume(path: &Path) -> PathBuf {
    path.ancestors().last().unwrap_or(path).to_path_buf()
}

/// The reading of a scope-owned store tagged `links = "shared-tree"`: the
/// scope's shared tree under the skill's canonical name.
pub(crate) fn shared_tree(env: &Env, scope: &Scope, name: &str) -> Position {
    Position {
        directory: crate::engine::desired::skill_canonical(env, scope, name),
        bound: scope_bound(env, scope),
    }
}

/// The reading of a template copy: the saving project's shared tree,
/// bounded by that project, so it reads relative to whichever scope
/// installs it.
pub(crate) fn template(project: &Path, name: &str) -> Position {
    shared_tree_of(project, name)
}

fn shared_tree_of(project: &Path, name: &str) -> Position {
    Position {
        directory: project
            .join(".agents/skills")
            .join(crate::harness::canonical_name(name)),
        bound: project.to_path_buf(),
    }
}

/// The reading of a destination catalog: its item directory, bounded by
/// the catalog root, so nothing outside the catalog is written into it.
pub(crate) fn catalog(root: &Path, item: &Path) -> Position {
    Position {
        directory: item.to_path_buf(),
        bound: root.to_path_buf(),
    }
}

/// The store a skill's bytes are kept in: the source holding them and the
/// reading its declaration records.
#[derive(Clone, Copy)]
pub(crate) struct Store<'a> {
    pub(crate) source: &'a str,
    pub(crate) links: Option<SkillLinks>,
}

impl<'a> From<&'a ItemDecl> for Store<'a> {
    fn from(decl: &'a ItemDecl) -> Self {
        Store {
            source: &decl.source,
            links: decl.links,
        }
    }
}

/// Whether the store is scope-owned content stored before kendex fixed a
/// reading for it: [`Reading::AsDelivered`].
pub(crate) fn as_delivered(store: Store<'_>) -> bool {
    matches!(store.source, LOCAL_SOURCE_NAME | INPLACE_SOURCE_NAME) && store.links.is_none()
}

/// The reading a stored skill's bytes hold. `item` is where the source
/// keeps the item and `sealed` the catalog it is read from.
pub(crate) fn declared(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    store: Store<'_>,
    name: &str,
    item: &Path,
    sealed: &SealedSource,
) -> Reading {
    if as_delivered(store) {
        return Reading::AsDelivered;
    }
    match store.source {
        LOCAL_SOURCE_NAME | INPLACE_SOURCE_NAME => Reading::Fixed {
            position: shared_tree(env, scope, name),
            siblings: Siblings::SkillsDirectory,
        },
        source => match manifest.sources.get(source) {
            Some(declared) if declared.path.is_some() => Reading::Fixed {
                position: Position {
                    directory: item.to_path_buf(),
                    bound: scope_bound(env, scope),
                },
                siblings: Siblings::Catalog(sealed.clone()),
            },
            _ => Reading::Opaque,
        },
    }
}

/// An observed directory uses its scope position when physical identity
/// proves it is the shared tree. Identity follows links; interpretation
/// retains the scope spelling so a linked ancestor cannot change `..`.
/// Other folders retain their own position, including hand-made sharing.
pub(crate) fn observed(env: &Env, scope: &Scope, name: &str, directory: PathBuf) -> Position {
    let shared = shared_tree(env, scope, name);
    let directory = match (
        crate::paths::canonical(&directory),
        crate::paths::canonical(&shared.directory),
    ) {
        (Ok(at), Ok(shared_at)) if at == shared_at => shared.directory,
        // A foreign leaf link names a hand-made folder at its target;
        // only a known shared-tree alias has a scope-owned reading.
        (Ok(at), _) if directory.is_symlink() => at,
        _ => directory,
    };
    Position {
        directory,
        bound: scope_bound(env, scope),
    }
}

/// Recorded delivery positions, deduplicated by physical identity while
/// retaining their scope spelling for relative-link interpretation.
pub(crate) fn delivered(
    env: &Env,
    scope: &Scope,
    lock: &crate::lock::Lock,
    kind: ItemKind,
    name: &str,
) -> Vec<Position> {
    let mut directories = std::collections::BTreeMap::new();
    for path in lock
        .entries
        .values()
        .filter(|entry| entry.kind == kind && entry.name == name)
        .filter_map(|entry| entry.emitted.as_ref())
        .flat_map(|emitted| emitted.paths.iter())
    {
        if let Ok(identity) = crate::paths::canonical(path)
            && identity.is_dir()
        {
            directories
                .entry(identity)
                .or_insert_with(|| observed(env, scope, name, path.clone()));
        }
    }
    directories.into_values().collect()
}

/// The tree read from `origin` as it reads from `destination`: one
/// conversion of its regular files, under the destination's bound. Its link
/// files are not written through, so they are not part of the result.
pub(crate) fn convert(origin: Origin, destination: &Position) -> (Files, Vec<KeptLink>) {
    let mut kept = Vec::new();
    let files = origin
        .files
        .into_iter()
        .map(|(rel, bytes)| {
            let bytes = match std::str::from_utf8(&bytes) {
                Ok(text) => {
                    let (text, unrepresentable) =
                        convert_text(text, &origin.directory, &rel, &origin.siblings, destination);
                    kept.extend(unrepresentable.into_iter().map(|target| KeptLink {
                        file: rel.clone(),
                        target,
                    }));
                    text.into_bytes()
                }
                Err(_) => bytes,
            };
            (rel, bytes)
        })
        .collect();
    (files, kept)
}

/// Every origin position interpreted into `destination`. One write stands
/// only when each position's content and link meanings agree, its link
/// files included; raw byte equality, position order and the order a
/// directory lists its entries in decide nothing.
pub(crate) fn agreed(
    first: Origin,
    rest: impl IntoIterator<Item = Origin>,
    destination: &Position,
) -> Converted {
    let position = first.directory.clone();
    let (expected, files, kept) = meaning(first, destination);
    for origin in rest {
        let other_position = origin.directory.clone();
        if meaning(origin, destination).0 != expected {
            return Converted::Disagree {
                positions: [position, other_position],
            };
        }
    }
    Converted::Agreed { files, kept }
}

/// What one position's tree means once interpreted into `destination`,
/// with its converted files and the links the conversion kept.
fn meaning(origin: Origin, destination: &Position) -> (Meaning, Files, Vec<KeptLink>) {
    let mut link_files: Vec<(PathBuf, Reaches)> = origin
        .link_files
        .iter()
        .map(|link| (link.file.clone(), reaches(&origin.directory, link)))
        .collect();
    link_files.sort();
    let (files, kept) = convert(origin, destination);
    let meaning = Meaning {
        files: comparable_tree(&files, &destination.directory),
        kept: kept_meanings(&kept, destination),
        link_files,
    };
    (meaning, files, kept)
}

/// What a tree means at its destination, in the form two positions
/// compare in.
#[derive(PartialEq, Eq)]
struct Meaning {
    files: Vec<(PathBuf, Vec<u8>)>,
    kept: Vec<(PathBuf, String)>,
    link_files: Vec<(PathBuf, Reaches)>,
}

/// What `link` reaches from the tree at `directory`. A move carries the
/// link as it is, so a copy that read it from another place reads
/// something else once that copy is gone.
fn reaches(directory: &Path, link: &LinkFile) -> Reaches {
    match crate::fs::resolved(&directory.join(&link.file), &link.target) {
        Some(at) => match at.strip_prefix(directory) {
            Ok(inside) => Reaches::Inside(inside.to_path_buf()),
            Err(_) => Reaches::Outside(at),
        },
        None => Reaches::Nowhere(link.target.clone()),
    }
}

/// A tree's regular files in the one form two readings of it at
/// `directory` compare in: every text file with each link respelled by the
/// target it resolves to there, every other byte exact, sorted by path.
pub(crate) fn comparable_tree(
    files: &[(PathBuf, Vec<u8>)],
    directory: &Path,
) -> Vec<(PathBuf, Vec<u8>)> {
    let mut compared: Vec<(PathBuf, Vec<u8>)> = files
        .iter()
        .map(|(rel, bytes)| {
            let bytes = match std::str::from_utf8(bytes) {
                Ok(text) => comparable(text, &directory.join(rel)).into_bytes(),
                Err(_) => bytes.clone(),
            };
            (rel.clone(), bytes)
        })
        .collect();
    compared.sort();
    compared
}

/// The links a conversion kept, by the file holding each and the target
/// it resolves to at `destination`.
fn kept_meanings(kept: &[KeptLink], destination: &Position) -> Vec<(PathBuf, String)> {
    let mut kept: Vec<(PathBuf, String)> = kept
        .iter()
        .map(|link| {
            (
                link.file.clone(),
                comparable(
                    &format!("[k]({})", link.target),
                    &destination.directory.join(&link.file),
                ),
            )
        })
        .collect();
    kept.sort();
    kept
}

/// The canonical form two texts at `file` compare in: each link
/// destination respelled by the target it resolves to. The managed
/// instructions block stays opaque, so a comparison never discards an edit
/// to its contents.
fn comparable(text: &str, file: &Path) -> String {
    match super::instructions_block_range(text) {
        Some((start, end)) => format!(
            "{}{}{}",
            crate::render::agent::compare_skill_links(&text[..start], file),
            &text[start..end],
            crate::render::agent::compare_skill_links(&text[end..], file)
        ),
        None => crate::render::agent::compare_skill_links(text, file),
    }
}

fn convert_text(
    text: &str,
    origin: &Path,
    rel: &Path,
    siblings: &Siblings,
    destination: &Position,
) -> (String, Vec<String>) {
    let convert = |part: &str| {
        crate::render::agent::rebase_skill(
            part,
            BodyPaths {
                source: &origin.join(rel),
                source_root: &destination.bound,
                rendered: &destination.directory.join(rel),
                install_root: &destination.bound,
            },
            |target| target.starts_with(origin) || sibling(origin, siblings, target),
        )
    };
    // The managed block is the project's, injected after conversion; its
    // links are neither converted nor judged.
    match super::instructions_block_range(text) {
        Some((start, end)) => {
            let (head, mut kept) = convert(&text[..start]);
            let (tail, tail_kept) = convert(&text[end..]);
            kept.extend(tail_kept);
            (format!("{head}{}{tail}", &text[start..end]), kept)
        }
        None => convert(text),
    }
}

/// Whether `target` lies in another skill tree beside `origin`, which
/// moves with its own tree.
fn sibling(origin: &Path, siblings: &Siblings, target: &Path) -> bool {
    let Some(parent) = origin.parent() else {
        return false;
    };
    let Ok(rest) = target.strip_prefix(parent) else {
        return false;
    };
    let mut components = rest.components();
    let Some(tree) = components.next() else {
        return false;
    };
    match siblings {
        // A loose file beside the trees is not a tree.
        Siblings::SkillsDirectory => components.next().is_some(),
        Siblings::Catalog(sealed) => sealed.is_file(&parent.join(tree).join(SKILL_FILE)),
        Siblings::Unknown => false,
    }
}

/// The warning a writer returns for a link it kept: the bytes stay as
/// written and no longer claim the target they reached at the origin.
pub(crate) fn kept_warning(name: &str, link: &KeptLink) -> ItemWarning {
    ItemWarning {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        harness: None,
        message: format!(
            "{} links to {}, which may no longer reach its file",
            crate::paths::slashed(&link.file),
            link.target
        ),
        remediation: Some(
            "Use an absolute path or URL for a file outside the project or catalog.".to_owned(),
        ),
        detail: Some(format!(
            "skill-link-kept: {}: {}",
            crate::paths::slashed(&link.file),
            link.target
        )),
    }
}

/// The warning a move returns for a file that is a link inside the tree:
/// it is carried as it is and never written through, so its links were not
/// converted and make no claim to reach what they reached before.
pub(crate) fn not_converted_warning(name: &str, file: &Path) -> ItemWarning {
    ItemWarning {
        kind: ItemKind::Skill,
        name: name.to_owned(),
        harness: None,
        message: format!(
            "{} is a link, so the links inside it were not converted",
            crate::paths::slashed(file)
        ),
        remediation: Some(
            "Replace it with a regular file for its links to be converted.".to_owned(),
        ),
        detail: Some(format!(
            "skill-link-file-not-converted: {}",
            crate::paths::slashed(file)
        )),
    }
}

#[cfg(test)]
mod tests;
