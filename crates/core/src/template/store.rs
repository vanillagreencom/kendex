//! Where a template keeps the copies it owns, and the reads and writes
//! over them.
//!
//! A template's store is catalog-shaped — the same layout the local source
//! uses, resolved through the same [`crate::source::local_slot`] — so a
//! copy taken out of it installs by the ordinary path rules and nothing
//! here spells a second layout. The bytes are read back through
//! [`crate::source_read::SealedSource`], the one reader the rest of the
//! engine resolves a source tree with, so a link somebody dropped into the
//! store is refused here exactly as it is everywhere else.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::package::detail::PackageFile;
use crate::source::local_slot;
use crate::source_read::SealedSource;

use super::{Member, MemberSource, Template};

/// The tree one template's copies live in.
pub(super) fn root(env: &Env, id: &str) -> PathBuf {
    env.template_store_dir().join(id)
}

/// Where a package of this kind and name sits inside a template's store,
/// as the copy id records it: slash-separated and relative to the store,
/// so the recorded value is one spelling on every platform.
pub(super) fn slot_id(kind: ItemKind, name: &str) -> String {
    crate::paths::slashed(&local_slot(Path::new(""), kind, name))
}

/// The absolute path a recorded copy id resolves to inside its template's
/// store, refusing an id that would leave the store. A copy id is written
/// by [`slot_id`] and read back here; an id that escapes is a store
/// somebody edited, and reading through it would read a file the template
/// never captured.
pub fn copy_path(env: &Env, template: &Template, copy: &str) -> Result<PathBuf> {
    let root = root(env, &template.id);
    let mut path = root.clone();
    for segment in copy.split('/') {
        if segment.is_empty() || segment == "." || segment == ".." {
            return Err(CoreError::TemplateCopyUnreadable {
                copy: copy.to_owned(),
                why: "the copy is recorded at a path that leaves the template's store".to_owned(),
            });
        }
        path.push(segment);
    }
    Ok(path)
}

/// Write one package's bytes into a template's store and answer with the
/// copy id the member records. The store is the template's alone, so a
/// name already there is this template's own earlier copy of the same
/// package and is replaced whole.
pub(super) fn write(
    env: &Env,
    id: &str,
    kind: ItemKind,
    name: &str,
    files: &[(PathBuf, Vec<u8>)],
) -> Result<String> {
    if !crate::author::import::carries(kind) {
        return Err(CoreError::TemplateCopyUnreadable {
            copy: slot_id(kind, name),
            why: format!(
                "a {} is installed with the package that carries it, so a template keeps no copy of one",
                kind.name()
            ),
        });
    }
    let root = root(env, id);
    let slot = local_slot(&root, kind, name);
    if slot.exists() {
        remove_path(&slot)?;
    }
    match kind {
        // A skill is a tree; every other kind a copy carries is the one
        // file the slot names, and its read holds exactly one entry.
        ItemKind::Skill => {
            for (relative, bytes) in files {
                let target = slot.join(relative);
                write_file(&target, bytes)?;
            }
        }
        _ => {
            let Some((_, bytes)) = files.first() else {
                return Err(CoreError::TemplateCopyUnreadable {
                    copy: slot_id(kind, name),
                    why: "nothing was read to copy".to_owned(),
                });
            };
            write_file(&slot, bytes)?;
        }
    }
    Ok(slot_id(kind, name))
}

fn write_file(target: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    std::fs::write(target, bytes).map_err(|e| CoreError::io(target, e))
}

/// One copy's bytes, read back through the sealed reader: the tree for a
/// skill, the single file every other kind keeps. Relative paths, ready to
/// write under a destination's local source.
pub(super) fn read(
    env: &Env,
    template: &Template,
    member: &Member,
    copy: &str,
) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    let path = copy_path(env, template, copy)?;
    let root = root(env, &template.id);
    let unreadable = |why: String| CoreError::TemplateCopyUnreadable {
        copy: copy.to_owned(),
        why,
    };
    if !root.is_dir() {
        return Err(unreadable(
            "the template's store is not on this machine".to_owned(),
        ));
    }
    let sealed = SealedSource::open(&root).map_err(|e| unreadable(e.to_string()))?;
    let kind = member
        .kind
        .item()
        .ok_or_else(|| unreadable("a curated set has no copy of its own".to_owned()))?;
    if !crate::author::import::carries(kind) {
        return Err(unreadable(format!(
            "a {} is installed with the package that carries it, so a template keeps no copy of one",
            kind.name()
        )));
    }
    match kind {
        ItemKind::Skill => {
            if !sealed.is_dir(&path) {
                return Err(unreadable(
                    "the copy is not in the template's store".to_owned(),
                ));
            }
            sealed
                .collect_skill_tree(&path)
                .map_err(|e| unreadable(e.to_string()))
        }
        _ => {
            if !sealed.is_file(&path) {
                return Err(unreadable(
                    "the copy is not in the template's store".to_owned(),
                ));
            }
            let bytes = sealed.read(&path).map_err(|e| unreadable(e.to_string()))?;
            let leaf = path
                .file_name()
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(&member.name));
            Ok(vec![(leaf, bytes)])
        }
    }
}

/// Every file a template owns, for the file tree that inspects it, in the
/// shape every other file tree in kendex reads. A template with no copies
/// has none, which is not a failure.
pub fn stored_files(env: &Env, template: &Template) -> Result<Vec<PackageFile>> {
    let root = root(env, &template.id);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let sealed = SealedSource::open(&root)?;
    let mut files = Vec::new();
    walk(&sealed, &root, &root, &mut files)?;
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

fn walk(sealed: &SealedSource, root: &Path, dir: &Path, into: &mut Vec<PackageFile>) -> Result<()> {
    for entry in sealed.entries(dir)? {
        if sealed.is_dir(&entry) {
            walk(sealed, root, &entry, into)?;
            continue;
        }
        let Ok(relative) = entry.strip_prefix(root) else {
            continue;
        };
        let path = crate::paths::slashed(relative);
        into.push(PackageFile {
            is_readme: false,
            size: sealed.read(&entry)?.len().min(u32::MAX as usize) as u32,
            path,
        });
    }
    Ok(())
}

/// One file of a template's store as text, for the preview beside the
/// tree. Bytes that are not text are refused rather than shown as
/// replacement characters.
pub fn stored_file(env: &Env, template: &Template, path: &str) -> Result<String> {
    let target = copy_path(env, template, path)?;
    let root = root(env, &template.id);
    let sealed = SealedSource::open(&root)?;
    let bytes = sealed.read(&target)?;
    String::from_utf8(bytes).map_err(|_| CoreError::TemplateCopyUnreadable {
        copy: path.to_owned(),
        why: "the file is not text".to_owned(),
    })
}

/// Drop a template's whole store.
pub(super) fn remove(env: &Env, template: &Template) -> Result<()> {
    let root = root(env, &template.id);
    match root.exists() {
        true => remove_path(&root),
        false => Ok(()),
    }
}

/// Drop the copies a member removal left with nothing naming them. Only
/// this template's own store is touched, and only the copies no remaining
/// member records.
pub(super) fn prune(env: &Env, before: &Template, after: &Template) -> Result<()> {
    for member in &before.members {
        let MemberSource::Copy { copy, .. } = &member.source else {
            continue;
        };
        if after.members.iter().any(
            |held| matches!(&held.source, MemberSource::Copy { copy: kept, .. } if kept == copy),
        ) {
            continue;
        }
        let path = copy_path(env, before, copy)?;
        if path.exists() {
            remove_path(&path)?;
        }
    }
    Ok(())
}

fn remove_path(path: &Path) -> Result<()> {
    let removal = match path.is_dir() {
        true => std::fs::remove_dir_all(path),
        false => std::fs::remove_file(path),
    };
    removal.map_err(|e| CoreError::io(path, e))
}
