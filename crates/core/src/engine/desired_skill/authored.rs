//! How much of a rendered skill tree its publisher wrote.
//!
//! One question, kept beside the render that answers it: the project's
//! instructions go into that tree as one block, and where the block landed
//! is the render's own answer rather than anything read back out of it.

use crate::render::skill::Rendered;

/// How much of this rendered tree its publisher wrote: everything outside
/// the block the renderer put the project's instructions in.
///
/// The block arrives as the offsets the render produced, carried down from
/// where it was written. Looking for it in the finished file instead would
/// be asking the project where its own text ends — and it would answer with
/// a literal end marker of its own, closing the block early and handing the
/// rest of what it injected to the publisher.
///
/// Saying it as a boundary is what carries an occurrence through the split.
/// The block stays in the head while the publisher's own sections move to
/// `references/`, so their line lands in another file and one severity
/// lighter than a rendering of their bytes alone puts it — nothing to match
/// it to there, while a boundary has nothing to match. It is then settled
/// at the weight it is scored at, which is the only weight that matters.
///
/// `None` when the project supplied instructions the rendering does not
/// carry the offsets of: nothing here can then say which lines are whose,
/// and a record that cannot be bounded settles nothing.
pub(super) fn authored_tree(rendered: &Rendered) -> Option<crate::quality::Authored> {
    let Some(block) = rendered.block() else {
        return Some(crate::quality::Authored::Around(None));
    };
    let (_, bytes) = rendered
        .files()
        .iter()
        .find(|(rel, _)| *rel == block.file)?;
    let text = std::str::from_utf8(bytes.get(..block.end)?).ok()?;
    Some(crate::quality::Authored::Around(Some(
        crate::quality::Injection {
            file: block.file.clone(),
            lines: (line_at(text, block.start), line_at(text, block.end - 1)),
        },
    )))
}

/// The line an offset falls on, counted from one, as a location names it.
fn line_at(text: &str, offset: usize) -> usize {
    text[..offset].matches('\n').count() + 1
}
