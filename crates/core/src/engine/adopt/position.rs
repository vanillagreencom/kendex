//! Where a tool reads an item, and which spelling of the toggled pair is
//! the one on disk. The question a surface asks and the place adoption
//! reads are answered here together, so an offer never names a position
//! the capture will not find.

use std::path::{Path, PathBuf};

use super::super::desired::native_dir;
use crate::env::Env;
use crate::model::{HarnessId, ItemKind, Scope};

/// The place one tool reads this item from — the only place adoption looks
/// for it. Read wherever a surface asks whether adoption could keep a
/// tool's copy, so the question and the action are one rule: an offer
/// naming a tool that has nothing here would error the moment it was
/// followed.
pub(in crate::engine) fn position(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    let dir = native_dir(env, scope, harness, kind)?;
    Some(match kind {
        ItemKind::Agent => dir.join(crate::render::agent::file_name(harness, name)),
        _ => dir.join(name),
    })
}

/// Whether both spellings of the toggled pair hold content. Keeping would
/// take one and leave the other, and a later switch reads what is left as
/// kendex's own — so the reader is asked to settle it first rather than
/// offered a move that takes half of it.
pub(in crate::engine) fn both_spellings(kind: ItemKind, at: &Path) -> bool {
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
    super::supports(kind)
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
