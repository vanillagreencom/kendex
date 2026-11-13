//! The one reading of relative links in stored skill bytes.
//!
//! Every stored skill tree's links mean what they reach from the one
//! position its store fixes: a path catalog's item directory, the scope's
//! shared tree for scope-owned content tagged `links = "shared-tree"`, a
//! destination catalog's item directory for an import. Untagged scope-owned
//! content and fetched catalogs carry their bytes as delivered and are never
//! converted or judged. The renderer and every writer that moves skill bytes
//! ask [`declared`] or a destination function for the reading, then convert
//! once, at the move, with [`convert`] or [`agreed`]; none repeats a source
//! name, fork record or containment match of its own.

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
pub(crate) enum Reading<'a> {
    /// Links mean what they reach from `position.directory`.
    Fixed {
        position: Position,
        siblings: Siblings<'a>,
    },
    /// Untagged scope-owned content: each position reads the bytes as it
    /// was delivered them. Never converted or judged.
    AsDelivered,
    /// A fetched catalog: the bytes are the publisher's contract.
    Opaque,
}

/// What may stand beside a reading position and move with its own tree, so
/// a link into it keeps its bytes.
#[derive(Clone, Copy)]
pub(crate) enum Siblings<'a> {
    /// A harness skills directory or the shared tree: every subdirectory
    /// is a skill tree.
    SkillsDirectory,
    /// An authored catalog: a directory the catalog gives a `SKILL.md`.
    Catalog(&'a SealedSource),
    /// A hand-made folder: nothing beside it is known to be a skill.
    Unknown,
}

/// One position a writer holds the tree at, with the bytes it holds there.
pub(crate) struct Origin<'a> {
    pub(crate) directory: PathBuf,
    pub(crate) files: Files,
    pub(crate) siblings: Siblings<'a>,
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

/// The reading a declared skill's stored bytes hold. `item` is where the
/// source keeps the item and `sealed` the catalog it is read from.
pub(crate) fn declared<'a>(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    decl: &ItemDecl,
    name: &str,
    item: &Path,
    sealed: &'a SealedSource,
) -> Reading<'a> {
    match decl.source.as_str() {
        LOCAL_SOURCE_NAME | INPLACE_SOURCE_NAME => match decl.links {
            Some(SkillLinks::SharedTree) => Reading::Fixed {
                position: shared_tree(env, scope, name),
                siblings: Siblings::SkillsDirectory,
            },
            None => Reading::AsDelivered,
        },
        source => match manifest.sources.get(source) {
            Some(declared) if declared.path.is_some() => Reading::Fixed {
                position: Position {
                    directory: item.to_path_buf(),
                    bound: scope_bound(env, scope),
                },
                siblings: Siblings::Catalog(sealed),
            },
            _ => Reading::Opaque,
        },
    }
}

/// The tree read from `origin` as it reads from `destination`: one
/// conversion, under the destination's bound.
pub(crate) fn convert(origin: Origin<'_>, destination: &Position) -> (Files, Vec<KeptLink>) {
    let mut kept = Vec::new();
    let files = origin
        .files
        .into_iter()
        .map(|(rel, bytes)| {
            let bytes = match std::str::from_utf8(&bytes) {
                Ok(text) => {
                    let (text, unrepresentable) =
                        convert_text(text, &origin.directory, &rel, origin.siblings, destination);
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
/// only when each position's content and link meanings agree; raw byte
/// equality and position order decide nothing.
pub(crate) fn agreed<'a>(
    first: Origin<'a>,
    rest: impl IntoIterator<Item = Origin<'a>>,
    destination: &Position,
) -> Converted {
    let position = first.directory.clone();
    let (files, kept) = convert(first, destination);
    let expected = meanings(&files, &kept, destination);
    for origin in rest {
        let other_position = origin.directory.clone();
        let (other, other_kept) = convert(origin, destination);
        if meanings(&other, &other_kept, destination) != expected {
            return Converted::Disagree {
                positions: [position, other_position],
            };
        }
    }
    Converted::Agreed { files, kept }
}

/// What a converted tree means at `destination`: every text file compared
/// by the targets its links resolve to, every other byte exact, and which
/// links were kept.
fn meanings(
    files: &Files,
    kept: &[KeptLink],
    destination: &Position,
) -> (Files, Vec<(PathBuf, String)>) {
    let mut compared: Vec<(PathBuf, Vec<u8>)> = files
        .iter()
        .map(|(rel, bytes)| {
            let bytes = match std::str::from_utf8(bytes) {
                Ok(text) => comparable(text, &destination.directory.join(rel)).into_bytes(),
                Err(_) => bytes.clone(),
            };
            (rel.clone(), bytes)
        })
        .collect();
    compared.sort();
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
    (compared, kept)
}

/// The canonical form two texts at `file` compare in: each link
/// destination respelled by the target it resolves to. The managed
/// instructions block stays opaque, so a comparison never discards an edit
/// to its contents.
pub(crate) fn comparable(text: &str, file: &Path) -> String {
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
    siblings: Siblings<'_>,
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
fn sibling(origin: &Path, siblings: Siblings<'_>, target: &Path) -> bool {
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
            "skill-link-kept: {}: {}",
            crate::paths::slashed(&link.file),
            link.target
        ),
        remediation: Some(
            "the link keeps its spelling, which no longer claims the file it reached before; use an absolute path or URL for a target outside the project or catalog".to_owned(),
        ),
        detail: None,
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
            "skill-link-file-not-converted: {}",
            crate::paths::slashed(file)
        ),
        remediation: Some(
            "the file is a link and kept as it is; replace it with a regular file for its links to be converted".to_owned(),
        ),
        detail: None,
    }
}

#[cfg(test)]
mod tests;
