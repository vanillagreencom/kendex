//! Where a tool reads an adoptable item from, whether it has one there,
//! and whether the tools named together hold one copy or several.
//!
//! The question a surface asks before drawing a Keep, and the place the
//! verb reads, answered here together — an offer naming a tool that has
//! nothing, or a set the capture would have to merge, would error the
//! moment it was followed.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::{HarnessId, ItemKind, Scope};

use super::capture::{Seen, look};
use super::{already_managed, destination, hooks, supports, usable};

// Where a tool reads an item, and which spelling of the toggled pair is
// the one on disk. The question a surface asks and the place adoption
// reads are answered here together, so an offer never names a position
// the capture will not find.

/// The place one tool reads an adoptable item from — the only place
/// adoption looks for it. Answered for the kinds `supports` takes and no
/// others, so the arms are the whole of what adoption can be asked. Read
/// wherever a surface asks whether adoption could keep a tool's copy, so
/// the question and the action are one rule: an offer naming a tool that
/// has nothing here would error the moment it was followed.
pub(crate) fn position(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    // No position for a name no path may be derived from: this answers
    // "has this tool something to keep", and a name adoption refuses has
    // nothing anywhere.
    usable(name).ok()?;
    // Where the tool would put it, and — for a tool that reads its own
    // folder as well as the shared one — where it may already have it. The
    // occupied place wins: a person's own copy predates the shared
    // convention, and adoption exists to take exactly that.
    let mut places = crate::engine::desired::read_dirs(env, scope, harness, kind)
        .into_iter()
        .filter_map(|dir| at(kind, &dir, name, harness));
    let first = places.next()?;
    Some(match there(&first) {
        true => first,
        false => places.find(|place| there(place)).unwrap_or(first),
    })
}

/// One item's path inside a directory the harness reads it from.
fn at(kind: ItemKind, dir: &Path, name: &str, harness: HarnessId) -> Option<PathBuf> {
    Some(match kind {
        ItemKind::Agent => dir.join(crate::render::agent::file_name(harness, name)),
        // A `/` never survives into an installed skill: the tool holds
        // `plugin/item` as one directory, `plugin__item` or
        // `plugin-item`. Reading nested directories instead would find
        // nothing, and report a skill plainly there as absent.
        ItemKind::Skill => dir.join(crate::harness::rendered_name(harness, name)),
        // No other kind reaches here: `supports` gates `can_keep_for`,
        // and a shared-link row exists only where `link_target` said yes,
        // which is skills only. Nothing, rather than a guess that would
        // read as a contract for a renderer this does not speak for.
        _ => return None,
    })
}

/// Whether both spellings of the toggled pair hold content. Keeping would
/// take one and leave the other, and a later switch reads what is left as
/// kendex's own — so the reader is asked to settle it first rather than
/// offered a move that takes half of it.
pub(crate) fn both_spellings(kind: ItemKind, at: &Path) -> bool {
    match kind {
        ItemKind::Skill => there(&at.join("SKILL.md")) && there(&at.join("SKILL.md.disabled")),
        _ => there(at) && there(&crate::engine::file_plan::toggle_sibling(at)),
    }
}

/// Whether this tool has something adoption can keep. A tool with an empty
/// position is never named in an offer: adoption works at that position and
/// nowhere else, and the folder a link points at is reached through the
/// tool whose own place is the link.
///
/// A skill is a folder holding a `SKILL.md` — that is what the local source
/// finds again afterwards. Kept without one, the folder goes to the trash,
/// the declaration is rewritten around a source that has nothing to give,
/// and the apply that follows installs nothing: the reader is told their
/// files were kept and they are gone.
pub fn can_keep_for(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> bool {
    supports(kind)
        // Fail-closed: the destination the capture would use, so a Keep
        // is never drawn for one the verb refuses, and a source that
        // cannot be read is not one that said yes.
        && destination(env, scope, kind, name).is_ok()
        && position(env, scope, kind, name, harness).is_some_and(|path| {
            !both_spellings(kind, &path)
                && match kind {
                    // The marker is a file the capture reads. A directory
                    // wearing its name is not one, and taking the tree
                    // would trash the original for a source that has
                    // nothing to give back.
                    ItemKind::Skill => path.join("SKILL.md").is_file(),
                    _ => there(&path),
                }
        })
}

fn there(path: &Path) -> bool {
    path.exists() || path.is_symlink()
}

/// Where an item's files sit, and what the capture would make of them.
pub(super) struct Held {
    pub(super) local_item: PathBuf,
    pub(super) positions: Vec<(HarnessId, PathBuf)>,
    pub(super) seen: Seen,
}

/// What the named tools hold where this item goes, read through the
/// boundaries the capture applies: a position it cannot find, one kendex
/// already manages, one carrying both spellings of a togglable name, and
/// copies the tools disagree on all refuse here. `adopt` plans from this
/// and `exits` asks it, so a Keep is never offered for a set these
/// refusals would meet. They are not every refusal adoption has —
/// `can_keep_all` names the kind whose own planner holds the rest.
///
/// `scope` is already canonical: positions come from the caller's scope
/// while a link's target comes back resolved off disk (invariant 17).
pub(super) fn read_positions(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
) -> Result<Held> {
    let local_item = destination(env, scope, kind, name)?;
    let mut positions: Vec<(HarnessId, PathBuf)> = Vec::new();
    for &harness in harnesses {
        let Some(original) = position(env, scope, kind, name, harness) else {
            return Err(CoreError::ItemNotInSource {
                name: name.to_owned(),
                source_name: format!("{} {}", harness.name(), kind.name()),
            });
        };
        // Two tools reading one directory sit at one position, captured once.
        if !positions.iter().any(|(_, path)| path == &original) {
            positions.push((harness, original));
        }
    }
    if positions.is_empty() {
        return Err(CoreError::ItemNotInSource {
            name: name.to_owned(),
            source_name: "no tool was named to keep it for".to_owned(),
        });
    }
    // Adoption takes what kendex did not write. A position it did write is
    // already looked after, and capturing it would move an installation
    // into the local source and rewrite the declaration around it — a
    // catalog-tracked item quietly becoming a fork of itself. The page a
    // keep was clicked on can be a minute old, and something else can have
    // installed the item in between.
    //
    // A lock that cannot be read is not an empty one: read as empty, every
    // installation on this machine would look like a stranger's files.
    let owned: std::collections::BTreeSet<PathBuf> =
        crate::lock::load(&crate::lock::lock_path(env, scope))?
            .entries
            .values()
            .flat_map(|entry| crate::engine::owned::installed(env, scope, entry).files)
            .collect();
    // Where a position leads, not only where it sits: a link somebody made
    // can point at another item's installation, and the capture moves what
    // it points at.
    // Anywhere an installation lives, not only its exact root: a link into
    // a folder inside a managed skill, or at a folder holding managed
    // installs, moves them just the same.
    let managed = |path: &Path| {
        let at = path.canonicalize();
        let touches = |ours: &PathBuf, at: &Path| ours.starts_with(at) || at.starts_with(ours);
        owned
            .iter()
            .any(|ours| touches(ours, path) || at.as_ref().is_ok_and(|at| touches(ours, at)))
    };
    if let Some((_, held)) = positions.iter().find(|(_, path)| managed(path)) {
        return Err(already_managed(name, held));
    }

    // The offer withholds this shape, and so does the verb: a reader can
    // name the item directly, and taking one spelling while the other
    // stays leaves a file a later switch reads as kendex's own.
    if let Some((_, at)) = positions.iter().find(|(_, at)| both_spellings(kind, at)) {
        return Err(CoreError::TogglesDiffer {
            name: name.to_owned(),
            detail: crate::names::shown(&at.display().to_string()),
        });
    }

    let seen = look(env, scope, kind, name, &positions, &local_item)?;
    Ok(Held {
        local_item,
        positions,
        seen,
    })
}

/// Whether one keep could take every place named here. Keeping is a single
/// move over all of them and the capture refuses a set that disagrees — two
/// tools holding copies that differ, a shared folder beside a copy held on
/// its own — which no place can answer alone. Asked through the same reader
/// the adoption itself uses, so the offer and the action cannot drift apart.
///
/// A hook is outside that. Its cross-installation refusal lives in the
/// declaration its own planner builds, not in the capture this reads, so a
/// hook whose tools register the item differently is still offered a keep
/// its adoption then refuses. The answer here is yes, not a checked yes.
pub fn can_keep_all(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harnesses: &[HarnessId],
) -> bool {
    // A hook is a script plus a registry entry, with no capture to read.
    // What its tools disagree about is read where the declaration is
    // built, which is not this reader, so this is an unchecked yes.
    if hooks::supports(kind) {
        return true;
    }
    read_positions(env, &scope.canonical(), kind, name, harnesses).is_ok()
}
