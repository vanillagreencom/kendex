//! Where a document's code blocks are, so the prose rewrite leaves them
//! alone and the fork walk reads their whitespace as content. Fenced and
//! indented blocks are both blocks; this module is the one place that says
//! which lines stand inside one.

/// A fence line: any leading whitespace, then three or more backticks or
/// tildes. `bare` — nothing but whitespace after the run — is what makes a
/// line eligible to close a fence rather than open one.
///
/// Indent is not a limit. Markdown allows three spaces at the top level, but
/// a block nested inside a list item starts four in, and that is the common
/// shape in a real skill: a scanner that stops at three reads the block as
/// prose and cuts or rewrites straight through it.
pub fn fence_marker(line: &str) -> Option<(char, usize, bool)> {
    let rest = line.trim_start();
    let marker = rest.chars().next().filter(|c| matches!(c, '`' | '~'))?;
    let run = rest.chars().take_while(|c| *c == marker).count();
    (run >= 3).then(|| (marker, run, rest[run..].trim().is_empty()))
}

/// Which lines of `text` stand inside a code block: between a fence's
/// markers, or under the first line of a run indented four spaces or a
/// tab. A block's own first line is not inside it — what stands above
/// that line is prose, and the blank between them separates the two.
///
/// Inside a block a blank line is a line of the block's own text; outside
/// one it separates paragraphs and carries nothing a reader would miss.
pub fn inside_a_block(text: &str) -> Vec<bool> {
    let lines: Vec<&str> = text.lines().collect();
    let mut inside = vec![false; lines.len()];
    let mut fence: Option<(char, usize)> = None;
    for (at, line) in lines.iter().enumerate() {
        inside[at] = fence.is_some();
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
    // A run of indented lines is a block of its own. Every line from the
    // one that opened it to the last it holds is inside it, blank lines
    // among them included — they are the block's, not separation between
    // blocks — and a blank run trailing it belongs to whatever follows.
    let mut opened: Option<usize> = None;
    for (at, line) in lines.iter().enumerate() {
        if inside[at] {
            opened = None;
            continue;
        }
        if line.trim().is_empty() {
            continue;
        }
        match line.starts_with("    ") || line.starts_with('\t') {
            true => {
                if let Some(from) = opened {
                    inside[from + 1..=at].fill(true);
                }
                opened = Some(at);
            }
            false => opened = None,
        }
    }
    inside
}
