//! Reading one kept package out of its catalog and writing it under the
//! local source: the bytes in source form, and the write op that lands
//! them without ever overwriting content already the person's own.

use std::path::PathBuf;

use crate::apply::{Op, PlannedOp, Pre};
use crate::engine::ItemWarning;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::manifest::{Manifest, SkillLinks};
use crate::model::{ItemKind, Scope};
use crate::render::skill::links;

use super::ClosureItem;
use crate::engine::agent_carry::{AgentCarry, agent_carry};

/// `(relative path, bytes)` pairs ready to write under the local target.
type SourceFiles = Vec<(PathBuf, Vec<u8>)>;

/// What one kept item stores: its files, ready to write under the local
/// target, the reading its links were stored in, the catalog tables an
/// agent's rendering depended on, and what the link conversion reports.
pub(super) struct SourceForm {
    pub(super) files: SourceFiles,
    pub(super) links: Option<SkillLinks>,
    pub(super) carry: Option<AgentCarry>,
    pub(super) warnings: Vec<ItemWarning>,
}

/// One item's source-form files, read through the sealed catalog at the commit
/// it was installed from: the skill's tree, or the single file the other kinds
/// keep. A skill's links are converted into the local source's shared-tree
/// reading while the catalog still says where they were read from.
pub(super) fn source_form(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &crate::lock::Lock,
    item: &ClosureItem,
    commit: Option<&str>,
    in_scope: &crate::engine::ScopeSkills,
) -> Result<SourceForm> {
    let resolved =
        crate::source::require_ready_at(env, scope, &item.decl.source, manifest, commit)?;
    let sealed = crate::source_read::SealedSource::open(&resolved.root)?;
    let config = crate::source::source_config_for(&sealed, &resolved.provenance)?;
    let Some(path) = crate::source::find_item(&sealed, &config, item.kind, &item.name) else {
        return Err(CoreError::ItemNotInSource {
            name: item.name.clone(),
            source_name: item.decl.source.clone(),
        });
    };
    match item.kind {
        ItemKind::Skill => {
            let files = sealed.collect_skill_tree(&path)?;
            // A subdirectory carrying its own SKILL.md is a nested skill —
            // captured as its own item, so its files are not this skill's
            // content. Without this, keeping both `plugin` and `plugin/item`
            // would write `item`'s bytes twice and the second write would clash.
            let nested: Vec<PathBuf> = files
                .iter()
                .filter_map(|(rel, _)| {
                    let parent = rel.parent()?;
                    (!parent.as_os_str().is_empty() && rel.file_name()? == "SKILL.md")
                        .then(|| parent.to_path_buf())
                })
                .collect();
            let files: SourceFiles = files
                .into_iter()
                .filter(|(rel, _)| !nested.iter().any(|dir| rel.starts_with(dir)))
                .collect();
            let (files, links, warnings) =
                stored_links(env, scope, manifest, lock, item, &path, &sealed, files);
            Ok(SourceForm {
                files,
                links,
                carry: None,
                warnings,
            })
        }
        _ => {
            let bytes = sealed.read(&path)?;
            let carry = match item.kind == ItemKind::Agent {
                true => agent_carry(manifest, &sealed, &config, &item.name, &bytes, in_scope)?,
                false => None,
            };
            let file = path
                .file_name()
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(&item.name));
            Ok(SourceForm {
                files: vec![(file, bytes)],
                links: None,
                carry,
                warnings: Vec::new(),
            })
        }
    }
}

/// A kept skill's files in the reading the local source stores them in.
///
/// A path catalog's links are read from the item directory. A fetched
/// catalog's bytes were delivered as they are, so each place they were
/// delivered to read them from there: where those places agree the tree is
/// converted, and where they disagree, or nothing records them, the bytes
/// are kept untagged so every place keeps reading what it was delivered.
#[allow(clippy::too_many_arguments)]
fn stored_links(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &crate::lock::Lock,
    item: &ClosureItem,
    path: &std::path::Path,
    sealed: &crate::source_read::SealedSource,
    files: SourceFiles,
) -> (SourceFiles, Option<SkillLinks>, Vec<ItemWarning>) {
    let destination = links::shared_tree(env, scope, &item.name);
    let converted = match links::declared(
        env,
        scope,
        manifest,
        (&item.decl).into(),
        &item.name,
        path,
        sealed,
    ) {
        links::Reading::Fixed { position, siblings } => {
            let (files, kept) = links::convert(
                links::Origin::new(position, files, siblings, Vec::new()),
                &destination,
            );
            let warnings = kept
                .iter()
                .map(|link| links::kept_warning(&item.name, link))
                .collect();
            return (files, Some(SkillLinks::SharedTree), warnings);
        }
        links::Reading::Opaque => {
            let mut origins = links::delivered(env, scope, lock, item.kind, &item.name)
                .into_iter()
                .map(|position| {
                    links::Origin::new(
                        position,
                        files.clone(),
                        links::Siblings::SkillsDirectory,
                        Vec::new(),
                    )
                });
            match origins.next() {
                Some(first) => links::agreed(first, origins, &destination),
                None => return (files, None, Vec::new()),
            }
        }
        // A catalog subscription is never the local store itself.
        links::Reading::AsDelivered => return (files, None, Vec::new()),
    };
    match converted {
        links::Converted::Agreed { files, kept } => {
            let warnings = kept
                .iter()
                .map(|link| links::kept_warning(&item.name, link))
                .collect();
            (files, Some(SkillLinks::SharedTree), warnings)
        }
        links::Converted::Disagree { positions } => {
            let warning = ItemWarning {
                kind: ItemKind::Skill,
                name: item.name.clone(),
                harness: None,
                message: "Kept as delivered, because its installed copies read its links differently; each copy keeps reading what it read before".to_owned(),
                remediation: None,
                detail: Some(format!(
                    "skill-links-delivered-apart: {}",
                    positions
                        .iter()
                        .map(|position| position.display().to_string())
                        .collect::<Vec<_>>()
                        .join(", ")
                )),
            };
            (files, None, vec![warning])
        }
    }
}

/// The write op for one detached item, after preflighting the local target:
/// an occupied target holding different bytes (a previous adopt, fork, or
/// detach of the same kind and name) is a refusal naming it — detach never
/// overwrites what is already local (invariants 4 and 6). A target already
/// holding the same bytes needs no write.
pub(crate) fn capture_to_local(
    kind: ItemKind,
    name: &str,
    target: &std::path::Path,
    files: Vec<(PathBuf, Vec<u8>)>,
) -> Result<Vec<PlannedOp>> {
    let occupied = |path: PathBuf| {
        Err(CoreError::LocalTargetOccupied {
            kind,
            name: name.to_owned(),
            path,
        })
    };
    // A symlink at the target is not owned local content: never followed, never
    // trusted as "already the same bytes" — a foreign link outside kendex's
    // trees must not be adopted as the local source.
    if target
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false)
    {
        return occupied(target.to_path_buf());
    }
    // A sibling that folds to the same name on a case- or composition-folding
    // filesystem would alias or overwrite this one on macOS or Windows, even
    // where an exact-path check on this planning host sees no collision.
    if let Some(sibling) = crate::names::folding_sibling(target)? {
        return occupied(sibling);
    }
    if target.exists() {
        let existing = crate::hash::hash_tree(target)?;
        let incoming = match kind {
            ItemKind::Skill => crate::hash::hash_files(&files),
            _ => crate::hash::hash_bytes(&files[0].1),
        };
        if existing == incoming {
            return Ok(Vec::new());
        }
        return occupied(target.to_path_buf());
    }
    let op = match kind {
        ItemKind::Skill => Op::WriteTree {
            root: target.to_path_buf(),
            files,
            pre: Pre::Absent,
        },
        _ => Op::WriteFile {
            path: target.to_path_buf(),
            bytes: files.into_iter().next().map(|(_, b)| b).unwrap_or_default(),
            pre: Pre::Absent,
        },
    };
    Ok(vec![PlannedOp {
        description: format!("keep {} {name} in your local source", kind.name()).into(),
        op,
    }])
}
