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

/// A fenced block standing open: what will close it, and the blockquote
/// depth its opening line stood at.
struct Fence {
    marker: char,
    run: usize,
    depth: usize,
}

/// A raw HTML block standing open, with the depth its opening line stood
/// at.
struct Raw {
    kind: Html,
    depth: usize,
}

fn place(lines: &[&str]) -> Vec<Placed> {
    let mut placed: Vec<Placed> = lines
        .iter()
        .map(|_| Placed {
            inside: false,
            block: None,
        })
        .collect();
    walk(lines, &mut placed);
    placed
}

/// Numbers the leaf blocks the lines carry and marks the ones a code block
/// holds.
///
/// A line is asked which container it stands in before it is asked what it
/// is. Everything a line can be — a fence's marker, a tag, an indent, a
/// heading — is read past the blockquote markers it carries, and a block
/// already open owns the markers it opened at and no others. Only a
/// paragraph continues lazily; a fence and a raw HTML block end where their
/// container stops, because a line that has dropped a marker has left them.
///
/// A run of indented lines is a block of its own, but only where no
/// paragraph stands open: markdown does not let four spaces interrupt one,
/// so under an open paragraph the same line is the paragraph's next line.
/// Every line from the one that opened such a block to the last it holds is
/// inside it, blank lines among them included — they are the block's, not
/// separation between blocks — and a blank run trailing it belongs to
/// whatever follows.
fn walk(lines: &[&str], placed: &mut [Placed]) {
    let mut fence: Option<Fence> = None;
    let mut raw: Option<Raw> = None;
    let mut code: Option<(usize, usize)> = None;
    let mut open: Option<Paragraph> = None;
    let mut next = 0;
    for (at, line) in lines.iter().enumerate() {
        let (depth, rest) = quote_depth(line, usize::MAX);
        if let Some(held) = &fence {
            match depth < held.depth {
                true => fence = None,
                false => {
                    placed[at].inside = true;
                    let (_, content) = quote_depth(line, held.depth);
                    if closes(held, content) {
                        fence = None;
                    }
                    open = None;
                    code = None;
                    continue;
                }
            }
        }
        if let Some(held) = &raw {
            match depth < held.depth {
                true => raw = None,
                false => {
                    let (_, content) = quote_depth(line, held.depth);
                    if html_closes(held.kind, content) {
                        raw = None;
                    }
                    open = None;
                    code = None;
                    continue;
                }
            }
        }
        if line.trim().is_empty() {
            open = None;
            continue;
        }
        // The paragraph this line could continue: one standing at this
        // depth or shallower. A line entering a deeper quote has left the
        // paragraph above it whatever else the line turns out to be, so
        // every question below asks this rather than whether any
        // paragraph at all is open.
        let running = open.filter(|para| depth <= para.depth);
        // A fence's marker stands at most three spaces into its container,
        // and a fourth is the indented code block instead. This walk knows
        // one container, so the cap is measurable exactly where a
        // blockquote's markers have been taken off. At the top level it is
        // not: nothing here tells a document's own indent from a list
        // item's content column, and a fenced block inside a list item
        // starts four in, which is the common shape in a real skill.
        if !(depth > 0 && indented(rest))
            && let Some((marker, run, _)) = fence_marker(rest)
        {
            fence = Some(Fence { marker, run, depth });
            open = None;
            code = None;
            continue;
        }
        if let Some(kind) = html_opens(rest, running.is_some()) {
            raw = (!html_closes(kind, rest)).then_some(Raw { kind, depth });
            open = None;
            code = None;
            continue;
        }
        // A thematic break, a setext underline and a blockquote marker with
        // nothing behind it each end the block above them and carry no
        // inline content of their own.
        let underline = running.is_some_and(|para| para.depth == depth) && setext_underline(rest);
        if thematic_break(rest) || underline || rest.trim().is_empty() {
            open = None;
            code = None;
            continue;
        }
        let continues = running.is_some() && !atx_heading(rest) && !list_marker(rest);
        if !continues && indented(rest) {
            if let Some((held, from)) = code
                && held == depth
            {
                placed[from + 1..=at]
                    .iter_mut()
                    .for_each(|line| line.inside = true);
            }
            code = Some((depth, at));
            open = None;
            continue;
        }
        code = None;
        match (continues, running) {
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

/// Whether this line closes the open fence: the same marker, a run at
/// least as long, and nothing behind it.
fn closes(fence: &Fence, content: &str) -> bool {
    !(fence.depth > 0 && indented(content))
        && fence_marker(content)
            .is_some_and(|(marker, run, bare)| marker == fence.marker && run >= fence.run && bare)
}
