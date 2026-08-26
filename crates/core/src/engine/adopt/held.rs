//! Where a tool reads an adoptable item from, and whether it has one there.
//!
//! The question a surface asks before drawing a Keep, and the place the
//! verb reads, answered here together — an offer naming a tool that has
//! nothing would error the moment it was followed.

use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

use super::{destination, supports, usable};

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
