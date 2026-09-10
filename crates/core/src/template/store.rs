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

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::ItemKind;
use crate::package::detail::PackageFile;
use crate::source::local_slot;
use crate::source_read::SealedSource;

use super::{Member, MemberSource, Template};

/// One package's copied files, as the `(relative path, bytes)` pairs
/// every write and read in this module passes around.
type CopyFiles = Vec<(PathBuf, Vec<u8>)>;

/// One slot and what it held before a replacement began writing over it:
/// its kind, its name, and its former bytes, or `None` where the slot was
/// empty.
type PriorSlot = (ItemKind, String, Option<CopyFiles>);

/// The tree one template's copies live in.
pub(super) fn root(env: &Env, id: &str) -> PathBuf {
    env.template_store_dir().join(id)
}

/// The sealed store, and one template's root inside it once the way to
/// that root has been judged.
///
/// The seal is the store DIRECTORY, never the template's own root:
/// [`SealedSource::open`] canonicalizes what it is given, so a root sealed
/// as itself is a link followed, and every path below the link's target
/// then answers as contained. Sealed one level up, a template's own folder
/// is a component the containment walk judges like any other — and that
/// walk is the judge this repository already keeps for a path outside a
/// root and for a link anywhere below it. Nothing here spells a second one.
///
/// Every read and every write in this module goes through the pair, so a
/// link standing where a template's folder belongs cannot redirect a slot
/// write, a licence write, a delete, or the bytes a surface displays.
///
/// The store directory is made before it is sealed: a reader needs a
/// directory, and the first write of the first template arrives before
/// anything has made one — a check skipped for an absent store would be a
/// check that write never gets.
fn sealed_store(env: &Env, id: &str) -> Result<(SealedSource, PathBuf)> {
    let store = env.template_store_dir();
    std::fs::create_dir_all(&store).map_err(|e| CoreError::io(&store, e))?;
    let sealed = SealedSource::open(&store)?;
    let root = store.join(id);
    sealed.contained(&root)?;
    Ok((sealed, root))
}

/// Where a package of this kind and name sits inside a template's store,
/// as the copy id records it: slash-separated and relative to the store,
/// so the recorded value is one spelling on every platform.
pub(super) fn slot_id(kind: ItemKind, name: &str) -> String {
    crate::paths::slashed(&local_slot(Path::new(""), kind, name))
}

/// The ids a set of notice files is recorded under: their paths inside the
/// store, spelled the one way [`slot_id`] spells a copy's.
pub(super) fn notice_ids(notices: &[(PathBuf, Vec<u8>)]) -> Vec<String> {
    notices
        .iter()
        .map(|(relative, _)| crate::paths::slashed(relative))
        .collect()
}

/// Every copy the template holds: where its bytes are inside the store,
/// and the notices they came under. The one reading of which members own
/// bytes here; everything this module derives about the store derives
/// from it.
fn held_copies(template: &Template) -> impl Iterator<Item = (&str, &[String])> {
    template
        .members
        .iter()
        .filter_map(|member| match &member.source {
            MemberSource::Copy { copy, notices, .. } => Some((copy.as_str(), notices.as_slice())),
            MemberSource::Marketplace { .. } => None,
        })
}

/// The notices the template's copies came under, by their store ids.
fn held_notices(template: &Template) -> impl Iterator<Item = &str> {
    held_copies(template).flat_map(|(_, notices)| notices.iter().map(String::as_str))
}

/// Every path inside the store the template's copies account for: each
/// copy's own slot, and the notices its bytes came under.
fn held_paths(template: &Template) -> impl Iterator<Item = &str> {
    held_copies(template)
        .flat_map(|(copy, notices)| std::iter::once(copy).chain(notices.iter().map(String::as_str)))
}

/// The absolute path a recorded copy id resolves to inside its template's
/// store, refusing an id that would leave the store. A copy id is written
/// by [`slot_id`] and read back here; an id that escapes is a store
/// somebody edited, and resolving one would reach a file the template
/// never captured — a file this module then reads, and prunes.
///
/// Every segment answers to [`crate::names::segment_problem`], the rule
/// this repository already keeps for what a name may be and what Windows
/// will quietly make of one, applied the way `pi_ext::files::inside`
/// applies it. That is the judge on purpose: a test against the literal
/// `.` and `..` is a second, weaker rule that never sees `..\victim`,
/// where the backslash is the separator; nor `C:..`, where the colon opens
/// a drive; nor `.. `, which Windows trims back to `..` after any
/// comparison has passed it. The path is built from the segments checked
/// here rather than by joining the recorded string, so nothing unexamined
/// reaches the filesystem.
///
/// A segment naming nothing — an empty one from a leading or doubled
/// separator, or `.` — is refused rather than skipped. `slot_id` writes
/// neither, so an id carrying one is an index somebody edited, and the
/// rule already says so.
pub fn copy_path(env: &Env, template: &Template, copy: &str) -> Result<PathBuf> {
    inside(&root(env, &template.id), copy).map_err(|problem| CoreError::TemplateCopyUnreadable {
        copy: copy.to_owned(),
        why: format!("the copy is recorded at a path this store cannot hold: {problem}"),
    })
}

/// One store-relative path resolved under `root`, or why a segment of it is
/// not one this store may hold.
///
/// The rule [`copy_path`] documents, in one place because a second caller
/// asks it: the notice writes in [`write()`] resolve their targets here too.
/// The path is built from the segments checked here rather than by joining
/// the string, so nothing unexamined reaches the filesystem, and the
/// caller spells the refusal its own site gives.
fn inside(root: &Path, relative: &str) -> std::result::Result<PathBuf, String> {
    let mut path = root.to_path_buf();
    for segment in relative.split('/') {
        if let Some(problem) = crate::names::segment_problem(segment) {
            return Err(problem);
        }
        path.push(segment);
    }
    Ok(path)
}

/// Write one package's bytes into a template's store and answer with the
/// copy id the member records. The store is the template's alone, so a
/// name already there is this template's own earlier copy of the same
/// package and is replaced whole.
///
/// `introduced` collects the licence files this write puts in the store
/// that were not there before it — what a rollback may remove, since a
/// notice that was already there is one an earlier copy still owns. A sink
/// rather than part of the answer because a write that refuses part-way
/// has already put some of them there, and a caller undoing the run needs
/// those too.
pub(super) fn write(
    env: &Env,
    id: &str,
    kind: ItemKind,
    name: &str,
    files: &[(PathBuf, Vec<u8>)],
    notices: &[(PathBuf, Vec<u8>)],
    introduced: &mut Vec<PathBuf>,
) -> Result<String> {
    // The name is joined into a path here and into the destination's
    // manifest at install. Asked again rather than trusted from the
    // caller: this is the one write in the template flow that does not go
    // through a plan, so nothing else would catch it.
    if let Some(problem) = crate::names::item_problem(name) {
        return Err(CoreError::TemplateCopyUnreadable {
            copy: name.to_owned(),
            why: problem,
        });
    }
    if !crate::author::import::carries(kind) {
        return Err(CoreError::TemplateCopyUnreadable {
            copy: slot_id(kind, name),
            why: format!(
                "a {} is installed with the package that carries it, so a template keeps no copy of one",
                kind.name()
            ),
        });
    }
    let (sealed, root) = sealed_store(env, id)?;
    // Where a licence file is allowed to land, asked of every segment of
    // every one of them before any of them is written. The relative path
    // carries a subscription alias the person typed, and this is the
    // boundary it may not leave: a path built by joining it unexamined
    // would put licence bytes outside the store, and the prune that reads
    // this store back would never see them.
    let notice_target = |relative: &Path| -> Result<PathBuf> {
        inside(&root, &crate::paths::slashed(relative)).map_err(|problem| {
            CoreError::TemplateCopyUnreadable {
                copy: slot_id(kind, name),
                why: format!("the terms are recorded at a path this store cannot hold: {problem}"),
            }
        })
    };
    // The terms first, before a byte of the copy moves: a licence file
    // already there under different bytes refuses, and a refusal that
    // arrived after the slot had been replaced would have taken the copy
    // this template held with it.
    for (relative, bytes) in notices {
        let target = notice_target(relative)?;
        match crate::author::import::notice_standing(&target, bytes) {
            crate::author::import::NoticeStanding::Absent
            | crate::author::import::NoticeStanding::Same => {}
            crate::author::import::NoticeStanding::Different => {
                return Err(CoreError::TemplateCopyUnreadable {
                    copy: slot_id(kind, name),
                    why: format!(
                        "this template already holds different terms at {} — the licence text changed, so remove that file or save this copy in another template",
                        crate::paths::slashed(relative)
                    ),
                });
            }
        }
    }
    let slot = local_slot(&root, kind, name);
    remove_inside(&sealed, &slot)?;
    match kind {
        // A skill is a tree; every other kind a copy carries is the one
        // file the slot names, and its read holds exactly one entry.
        ItemKind::Skill => {
            for (relative, bytes) in files {
                let target = slot.join(relative);
                write_file(&sealed, &target, bytes)?;
            }
        }
        _ => {
            let Some((_, bytes)) = files.first() else {
                return Err(CoreError::TemplateCopyUnreadable {
                    copy: slot_id(kind, name),
                    why: "nothing was read to copy".to_owned(),
                });
            };
            write_file(&sealed, &slot, bytes)?;
        }
    }
    // The terms travel with the bytes. Written beside the copy, at the
    // paths a catalog-shaped tree keeps them under, so an install reads
    // them back without knowing which origin they came from. Bytes
    // already there are the same bytes — the loop above refused anything
    // else — so one licence file two copies came under is written once.
    for (relative, bytes) in notices {
        let target = notice_target(relative)?;
        if crate::author::import::notice_standing(&target, bytes)
            == crate::author::import::NoticeStanding::Absent
        {
            write_file(&sealed, &target, bytes)?;
            introduced.push(relative.clone());
        }
    }
    Ok(slot_id(kind, name))
}

/// What a template's store holds at one package's slot right now, or
/// `None` where the slot is empty. Read before a replacement so the
/// replacement can be undone.
pub(super) fn held(
    env: &Env,
    template: &Template,
    kind: ItemKind,
    name: &str,
) -> Result<Option<CopyFiles>> {
    let slot = local_slot(&root(env, &template.id), kind, name);
    if !slot.exists() {
        return Ok(None);
    }
    let (sealed, _) = sealed_store(env, &template.id)?;
    match kind {
        ItemKind::Skill => Ok(Some(sealed.collect_skill_tree(&slot)?)),
        _ => {
            let leaf = slot
                .file_name()
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(name));
            Ok(Some(vec![(leaf, sealed.read(&slot)?)]))
        }
    }
}

/// Put back what [`held`] read, slot by slot, and take out the licence
/// files the run introduced. A slot that held nothing is emptied again, so
/// a fresh copy a refused replacement wrote does not survive it.
///
/// `introduced` is what [`write()`] reported putting there — never a notice
/// that was already in the store, which an earlier copy came under and
/// still owns. Nothing else sweeps one: [`prune`] removes only what a
/// member no longer names, and a file no member ever named is not that, so
/// one left here would sit where the terms comparison looks and refuse the
/// next legitimate copy whose licence text differs from it.
pub(super) fn restore(
    env: &Env,
    template: &Template,
    slots: &[PriorSlot],
    introduced: &[PathBuf],
) -> Result<()> {
    let (sealed, root) = sealed_store(env, &template.id)?;
    for (kind, name, before) in slots {
        let slot = local_slot(&root, *kind, name);
        remove_inside(&sealed, &slot)?;
        let Some(files) = before else {
            continue;
        };
        match kind {
            ItemKind::Skill => {
                for (relative, bytes) in files {
                    write_file(&sealed, &slot.join(relative), bytes)?;
                }
            }
            _ => {
                if let Some((_, bytes)) = files.first() {
                    write_file(&sealed, &slot, bytes)?;
                }
            }
        }
    }
    // Through the same judge the deletes in this module go through: a
    // relative path is not proof of where it lands.
    for relative in introduced {
        remove_inside(&sealed, &root.join(relative))?;
    }
    Ok(())
}

/// The licence and attribution files this template's copies came under, at
/// their paths relative to the store root. Empty where no member's bytes
/// came under anybody's terms.
///
/// Derived from the copies the template holds, never from whatever sits
/// under the store's notices directory: a notice belongs to the copy that
/// required it, so a copy taken out takes its terms out of this set with
/// it. Two copies from one marketplace name the same file, and it is read
/// once.
pub(super) fn notices(env: &Env, template: &Template) -> Result<Vec<(PathBuf, Vec<u8>)>> {
    let wanted: BTreeSet<&str> = held_notices(template).collect();
    if wanted.is_empty() {
        return Ok(Vec::new());
    }
    let (sealed, _) = sealed_store(env, &template.id)?;
    let mut carried = Vec::new();
    for id in wanted {
        let path = copy_path(env, template, id)?;
        carried.push((PathBuf::from(id), sealed.read(&path)?));
    }
    Ok(carried)
}

/// One file written inside the sealed store, asked of the seal before a
/// byte moves.
///
/// `create_dir_all` and `write` both follow a link on the way to the
/// target, so the question is asked here rather than at each caller: bytes
/// placed past a link are bytes no later read of this store can reach, and
/// the place they land is somebody else's.
fn write_file(sealed: &SealedSource, target: &Path, bytes: &[u8]) -> Result<()> {
    sealed.contained(target)?;
    if let Some(parent) = target.parent() {
        std::fs::create_dir_all(parent).map_err(|e| CoreError::io(parent, e))?;
    }
    std::fs::write(target, bytes).map_err(|e| CoreError::io(target, e))
}

/// One path inside the sealed store removed, asked of the seal before the
/// removal — a delete resolves what it is given, so a link on the way to it
/// aims the removal at content this store does not own. Absent is nothing
/// to do.
fn remove_inside(sealed: &SealedSource, path: &Path) -> Result<()> {
    sealed.contained(path)?;
    match path.exists() {
        true => remove_path(path),
        false => Ok(()),
    }
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
    let (sealed, _) = sealed_store(env, &template.id).map_err(|e| unreadable(e.to_string()))?;
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
/// shape every other file tree in kendex reads.
///
/// Read off the copies the template holds — each copy's own files, and the
/// notices its bytes came under — rather than off whatever the store
/// directory contains, so the tree lists what the template holds and never
/// something a member that has gone left behind. A copy the store no
/// longer holds contributes no rows: the resolution is what reports it as
/// missing, and a tree cannot list a file that is not there. A template
/// with no copies has none, which is not a failure.
pub fn stored_files(env: &Env, template: &Template) -> Result<Vec<PackageFile>> {
    let root = root(env, &template.id);
    if !root.is_dir() {
        return Ok(Vec::new());
    }
    let (sealed, root) = sealed_store(env, &template.id)?;
    let mut files = Vec::new();
    for id in held_paths(template) {
        let path = copy_path(env, template, id)?;
        if sealed.is_dir(&path) {
            walk(&sealed, &root, &path, &mut files)?;
        } else if sealed.is_file(&path) {
            entry_of(&sealed, &root, &path, &mut files)?;
        }
    }
    files.sort_by(|a, b| a.path.cmp(&b.path));
    // Two copies from one marketplace name the same licence file, and the
    // tree shows it once.
    files.dedup_by(|a, b| a.path == b.path);
    Ok(files)
}

fn walk(sealed: &SealedSource, root: &Path, dir: &Path, into: &mut Vec<PackageFile>) -> Result<()> {
    for entry in sealed.entries(dir)? {
        if sealed.is_dir(&entry) {
            walk(sealed, root, &entry, into)?;
            continue;
        }
        entry_of(sealed, root, &entry, into)?;
    }
    Ok(())
}

/// One file's row, positioned by where it sits under the store root. A
/// path that is not under it is no file of this template's and is left
/// out.
fn entry_of(
    sealed: &SealedSource,
    root: &Path,
    at: &Path,
    into: &mut Vec<PackageFile>,
) -> Result<()> {
    let Ok(relative) = at.strip_prefix(root) else {
        return Ok(());
    };
    into.push(PackageFile {
        is_readme: false,
        size: sealed.read(at)?.len().min(u32::MAX as usize) as u32,
        path: crate::paths::slashed(relative),
    });
    Ok(())
}

/// One file of a template's store as text, for the preview beside the
/// tree. Bytes that are not text are refused rather than shown as
/// replacement characters.
pub fn stored_file(env: &Env, template: &Template, path: &str) -> Result<String> {
    let target = copy_path(env, template, path)?;
    let (sealed, _) = sealed_store(env, &template.id)?;
    let bytes = sealed.read(&target)?;
    String::from_utf8(bytes).map_err(|_| CoreError::TemplateCopyUnreadable {
        copy: path.to_owned(),
        why: "the file is not text".to_owned(),
    })
}

/// Drop a template's whole store.
pub(super) fn remove(env: &Env, template: &Template) -> Result<()> {
    let (sealed, root) = sealed_store(env, &template.id)?;
    remove_inside(&sealed, &root)
}

/// Drop what a member removal left with nothing naming it: the copies, and
/// the notices those copies came under. Only this template's own store is
/// touched, and only what no remaining member accounts for.
pub(super) fn prune(env: &Env, before: &Template, after: &Template) -> Result<()> {
    // Nothing to prune, and nothing to open a reader on: a template whose
    // copies are gone, or which never had any, has no store on disk.
    if !root(env, &before.id).is_dir() {
        return Ok(());
    }
    let (sealed, _) = sealed_store(env, &before.id)?;
    let kept: BTreeSet<&str> = held_paths(after).collect();
    for id in held_paths(before).collect::<BTreeSet<&str>>() {
        if kept.contains(id) {
            continue;
        }
        let path = copy_path(env, before, id)?;
        // Where the delete would actually land, asked of the same reader
        // every read of this store goes through: it refuses a path outside
        // the root, and any symlink on the way to one. A recorded id
        // cannot spell an escape past [`copy_path`], but a link dropped
        // into the store can still put a path inside it over content
        // outside — and this is a delete, so it is asked before the
        // removal rather than after it.
        remove_inside(&sealed, &path)?;
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
