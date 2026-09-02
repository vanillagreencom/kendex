//! Whether an origin's bytes may be offered at all, asked of every read
//! [`super::origins_of`] hands back.
//!
//! Its own file because it is the one judgement in `origins` that is not
//! about where bytes live: the rest of the module finds them, and this
//! decides whether a catalog could hold what was found.

use super::{Bytes, OriginRead};
use crate::model::ItemKind;

/// Why these bytes are not the markdown a catalog's agent slot holds, when
/// they are not.
///
/// A catalog keeps an agent at `agents/<name>.md`
/// ([`crate::source::local_slot`]) and an import copies the bytes into it
/// as they are. A harness that keeps its agents in some other format —
/// Codex writes TOML — offers files that would land there unchanged, and
/// nothing downstream catches it: the catalog check's structural pass
/// never validates an agent, so the author is told the package is fine and
/// every consumer's install refuses it. The offer is where it stops.
///
/// One question, and only one: are these bytes UTF-8 text carrying a
/// frontmatter block [`crate::frontmatter::split_said`] accepts. It is not
/// the whole of what an install later asks of the file —
/// [`crate::render::agent::parse_source_agent`] goes on to require a
/// `name:` and to refuse frontmatter it cannot parse, and shipped
/// producers emit a nameless block — so bytes that pass here can still be
/// refused at install for a reason this gate does not ask about. Widening
/// it is not a free improvement: a rename writes a missing name in through
/// [`crate::render::skill::bytes_named`], and that path works today.
///
/// Asked of the bytes, never of the extension. Cursor writes `.mdc` and a
/// switched-off agent is parked at `.md.disabled`; both are frontmatter,
/// and the spellings do not end.
fn agent_shape_problem(kind: ItemKind, bytes: &Bytes) -> Option<&'static str> {
    if kind != ItemKind::Agent {
        return None;
    }
    // A tree is unconstructible for an agent: `read_bytes` makes a skill a
    // tree and every other kind a file.
    let Bytes::File(bytes) = bytes else {
        return None;
    };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return Some("the file is not text");
    };
    crate::frontmatter::split_said(text).err()
}

/// One read judged: a read whose bytes a catalog cannot store loses them,
/// and with them its hash — the only thing a selection can name — and
/// carries the reason instead.
///
/// Every origin goes through here, because [`super::origins_of`] maps it
/// over everything `reads` produces. A producer added later is judged by
/// having been written, not by its author remembering to ask.
pub(super) fn offered(kind: ItemKind, mut read: OriginRead) -> OriginRead {
    let Some(bytes) = &read.bytes else {
        return read;
    };
    if let Some(problem) = agent_shape_problem(kind, bytes) {
        read.bytes = None;
        read.problem = Some(format!(
            "{problem}, and a catalog stores an agent as markdown"
        ));
    }
    read
}
