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
///
/// An item switched off parks its content under the suffixed name, and a
/// hand-made file sits there just as easily. The pair is one position, so
/// whichever spelling is on disk is the one adoption reads.
pub(in crate::engine) fn position(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> Option<PathBuf> {
    let dir = native_dir(env, scope, harness, kind)?;
    let plain = match kind {
        ItemKind::Agent => dir.join(crate::render::agent::file_name(harness, name)),
        _ => dir.join(name),
    };
    let parked = crate::engine::file_plan::toggle_sibling(&plain);
    let here = |at: &Path| at.exists() || at.is_symlink();
    Some(match here(&plain) || !here(&parked) {
        true => plain,
        false => parked,
    })
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
/// Whether both spellings of the toggled pair hold content. One item is
/// on or off, not both, so this is a choice only the reader can make.
pub(in crate::engine) fn both_spellings(kind: ItemKind, at: &Path) -> bool {
    match kind {
        ItemKind::Skill => there(&at.join("SKILL.md")) && there(&at.join("SKILL.md.disabled")),
        _ => there(at) && there(&crate::engine::file_plan::toggle_sibling(at)),
    }
}

pub fn can_keep_for(
    env: &Env,
    scope: &Scope,
    kind: ItemKind,
    name: &str,
    harness: HarnessId,
) -> bool {
    super::supports(kind)
        && position(env, scope, kind, name, harness).is_some_and(|path| {
            // Both spellings holding content is a choice only the reader
            // can make, so it is never offered as one kendex will settle.
            !both_spellings(kind, &path)
        })
        && position(env, scope, kind, name, harness).is_some_and(|path| match kind {
            // A skill folder keeps its name in either state — the marker
            // inside it is what carries the toggle.
            ItemKind::Skill => {
                there(&path.join("SKILL.md")) || there(&path.join("SKILL.md.disabled"))
            }
            _ => there(&path),
        })
}

fn there(path: &Path) -> bool {
    path.exists() || path.is_symlink()
}

/// Whether what is at this position is the switched-off spelling: the
/// suffixed name for a plain file, the suffixed marker inside a folder.
pub(in crate::engine) fn parked(kind: ItemKind, at: &Path) -> bool {
    match kind {
        ItemKind::Skill => !there(&at.join("SKILL.md")) && there(&at.join("SKILL.md.disabled")),
        _ => at
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.ends_with(".disabled")),
    }
}
