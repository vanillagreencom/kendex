//! Where a document's blocks are, so the prose rewrite leaves code alone,
//! the fork walk reads a block's whitespace as content, and a run of
//! backticks reaches only as far as the block it opened in.
//!
//! Markdown answers that from what stands open at each line — which
//! containers, and whether a paragraph is still running — not from the two
//! lines in hand. A lazy blockquote continuation drops its `>` and stays in
//! the same paragraph, and an indented line may not interrupt an open
//! paragraph, so neither question can be asked of a pair of neighbours.
//! This is a walk of the whole document for that reason.

use super::fences::{code_spans, fence_marker};
use super::marks::{
    Html, atx_heading, html_closes, html_opens, indented, list_marker, quote_depth,
    setext_underline, thematic_break,
};

/// Which lines of `text` stand inside a code block: between a fence's
/// markers, or under the first line of a run indented four spaces or a
/// tab. A block's own first line is not inside it — what stands above
/// that line is prose, and the blank between them separates the two.
///
/// Inside a block a blank line is a line of the block's own text; outside
/// one it separates paragraphs and carries nothing a reader would miss.
pub fn inside_a_block(text: &str) -> Vec<bool> {
    let lines: Vec<&str> = text.lines().collect();
    place(&lines).into_iter().map(|line| line.inside).collect()
}

/// The code spans of each line of `text`, as byte ranges local to its own
/// line. A run of backticks may close on a later line, so the lines are
/// read together rather than one at a time: a line a span crosses whole is
/// quoted for its whole length.
///
/// The reach is one leaf block, not the whole document. A run that meets
/// no match before its block ends quotes nothing, which is what stops one
/// stray backtick from reaching forward for a partner and quoting
/// everything in between — and a run reaching across a boundary would pair
/// two backticks markdown reads as literal characters and quote a whole
/// line nobody quoted. Lines carrying no inline content are left empty:
/// in a code block the marks are the shell's, not markdown's.
pub fn code_spans_by_line(text: &str) -> Vec<Vec<(usize, usize)>> {
    let lines: Vec<&str> = text.lines().collect();
    let placed = place(&lines);
    let mut spans: Vec<Vec<(usize, usize)>> = vec![Vec::new(); lines.len()];
    let mut from = 0;
    while from < lines.len() {
        let Some(block) = placed[from].block else {
            from += 1;
            continue;
        };
        let mut to = from;
        while to + 1 < lines.len() && placed[to + 1].block == Some(block) {
            to += 1;
        }
        let joined = lines[from..=to].join("\n");
        for (start, end) in code_spans(&joined) {
            let mut base = 0;
            for (offset, line) in lines[from..=to].iter().enumerate() {
                let last = base + line.len();
                if start < last && end > base {
                    spans[from + offset].push((start.max(base) - base, end.min(last) - base));
                }
                base = last + 1;
            }
        }
        from = to + 1;
    }
    spans
}

/// One line's place in the document. `inside` is a line standing inside a
/// code block, where whitespace is content a person can edit rather than
/// separation between sections. `block` numbers the leaf block whose
/// inline content the line carries, and is `None` wherever a line carries
/// none — a blank line, a code block's own text, a thematic break, a
/// fence's opening line, a raw HTML block.
///
/// The two readings differ over one line and say so by being separate
/// fields: the line an indented block opens on is code the safety rules
/// read, and is not a line whose whitespace the fork walk may take for a
/// block's own.
struct Placed {
    inside: bool,
    block: Option<usize>,
}

/// The paragraph standing open: the blockquote depth it runs at, and the
/// block its lines belong to. Depth is what tells a lazy continuation,
/// which drops markers, from a quote opening inside prose, which adds one.
#[derive(Clone, Copy)]
struct Paragraph {
    depth: usize,
    block: usize,
}

fn place(lines: &[&str]) -> Vec<Placed> {
    let mut placed: Vec<Placed> = lines
        .iter()
        .map(|_| Placed {
            inside: false,
            block: None,
        })
        .collect();
    fenced(lines, &mut placed);
    leaves(lines, &mut placed);
    placed
}

/// Marks the lines a fence holds. The opening line is not one of them: what
/// stands on it is the fence and its info string, and the block's own text
/// starts below.
fn fenced(lines: &[&str], placed: &mut [Placed]) {
    let mut fence: Option<(char, usize)> = None;
    for (at, line) in lines.iter().enumerate() {
        if fence.is_some() {
            placed[at].inside = true;
        }
        match (fence_marker(line), fence) {
            (Some((marker, run, bare)), Some((open, len)))
                if marker == open && run >= len && bare =>
            {
                fence = None;
            }
            (Some((marker, run, _)), None) => fence = Some((marker, run)),
            _ => {}
        }
    }
}

/// Numbers the leaf blocks the lines a fence left over carry, and marks the
/// indented ones as code.
///
/// A run of indented lines is a block of its own, but only where no
/// paragraph stands open: markdown does not let four spaces interrupt one,
/// so under an open paragraph the same line is the paragraph's next line.
/// Every line from the one that opened such a block to the last it holds is
/// inside it, blank lines among them included — they are the block's, not
/// separation between blocks — and a blank run trailing it belongs to
/// whatever follows.
fn leaves(lines: &[&str], placed: &mut [Placed]) {
    let mut open: Option<Paragraph> = None;
    let mut html: Option<Html> = None;
    let mut code: Option<usize> = None;
    let mut next = 0;
    for (at, line) in lines.iter().enumerate() {
        if placed[at].inside {
            open = None;
            code = None;
            continue;
        }
        let (depth, rest) = quote_depth(line);
        if let Some(kind) = html {
            html = (!html_closes(kind, rest)).then_some(kind);
            code = None;
            continue;
        }
        if line.trim().is_empty() {
            open = None;
            continue;
        }
        if let Some(kind) = html_opens(rest) {
            html = (!html_closes(kind, rest)).then_some(kind);
            open = None;
            code = None;
            continue;
        }
        // A fence's opening line, a thematic break, a setext underline and a
        // blockquote marker with nothing behind it each end the block above
        // them and carry no inline content of their own.
        let underline = open.is_some_and(|para| para.depth == depth) && setext_underline(rest);
        if fence_marker(line).is_some()
            || thematic_break(rest)
            || underline
            || rest.trim().is_empty()
        {
            open = None;
            code = None;
            continue;
        }
        let continues = open
            .is_some_and(|para| depth <= para.depth && !atx_heading(rest) && !list_marker(rest));
        if !continues && indented(rest) {
            if let Some(from) = code {
                placed[from + 1..=at]
                    .iter_mut()
                    .for_each(|held| held.inside = true);
            }
            code = Some(at);
            open = None;
            continue;
        }
        code = None;
        match (continues, open) {
            (true, Some(para)) => placed[at].block = Some(para.block),
            _ => {
                placed[at].block = Some(next);
                // An ATX heading is one line and a block of its own, so it
                // leaves nothing open for the line below to continue.
                open = (!atx_heading(rest)).then_some(Paragraph { depth, block: next });
                next += 1;
            }
        }
    }
}
