//! Where a document's code is, so the prose rewrite leaves it alone, the
//! fork walk reads a block's whitespace as content, and the safety rules
//! tell a switch named in a span from one a line would run. Fenced and
//! indented blocks are both blocks; this module is the one place that says
//! which lines stand inside one and where a line's inline spans are.

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
    stands(text)
        .into_iter()
        .map(|stand| stand == Stand::Inside)
        .collect()
}

/// Which lines of `text` are prose. Every line [`inside_a_block`] leaves
/// out except the one an indented block opens on: the four spaces that
/// opened it are the block's own text, so a `#` there opens a comment the
/// same as it does one line further down.
pub fn prose_lines(text: &str) -> Vec<bool> {
    stands(text)
        .into_iter()
        .map(|stand| stand == Stand::Prose)
        .collect()
}

/// Where one line stands. The two readings differ over one line and say
/// so by name: the line an indented block opens on is code the rules
/// read, and is not a line whose whitespace the fork walk may take for a
/// block's own.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Stand {
    Prose,
    Opens,
    Inside,
}

fn stands(text: &str) -> Vec<Stand> {
    let lines: Vec<&str> = text.lines().collect();
    let mut stand = vec![Stand::Prose; lines.len()];
    let mut fence: Option<(char, usize)> = None;
    for (at, line) in lines.iter().enumerate() {
        if fence.is_some() {
            stand[at] = Stand::Inside;
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
    // A run of indented lines is a block of its own. Every line from the
    // one that opened it to the last it holds is inside it, blank lines
    // among them included — they are the block's, not separation between
    // blocks — and a blank run trailing it belongs to whatever follows.
    let mut opened: Option<usize> = None;
    for (at, line) in lines.iter().enumerate() {
        if stand[at] == Stand::Inside {
            opened = None;
            continue;
        }
        if line.trim().is_empty() {
            continue;
        }
        match line.starts_with("    ") || line.starts_with('\t') {
            true => {
                match opened {
                    Some(from) => stand[from + 1..=at].fill(Stand::Inside),
                    None => stand[at] = Stand::Opens,
                }
                opened = Some(at);
            }
            false => opened = None,
        }
    }
    stand
}

/// Inline code spans of one line, as outer byte ranges. A run of backticks
/// closes only on a run of the same length, so a span may quote backticks
/// of its own, and a run that never meets its match is the literal
/// characters rather than an opener — which is what keeps one stray
/// backtick from reading the rest of a document as quoted.
pub fn code_spans(line: &str) -> Vec<(usize, usize)> {
    let bytes = line.as_bytes();
    let mut spans: Vec<(usize, usize)> = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] != b'`' {
            at += 1;
            continue;
        }
        let run = bytes[at..].iter().take_while(|b| **b == b'`').count();
        let mut scan = at + run;
        while scan < bytes.len() {
            if bytes[scan] != b'`' {
                scan += 1;
                continue;
            }
            let close = bytes[scan..].iter().take_while(|b| **b == b'`').count();
            if close == run {
                spans.push((at, scan + close));
                break;
            }
            scan += close;
        }
        at = match spans.last() {
            Some((start, end)) if *start == at => *end,
            _ => at + run,
        };
    }
    spans
}

/// The code spans of each of `lines`, as byte ranges local to its own
/// line. A run of backticks may close on a later line, so the lines are
/// read together rather than one at a time: a line a span crosses whole is
/// quoted for its whole length.
///
/// The reach is one paragraph — a run of `prose` lines with no blank among
/// them — not the whole document. A run that meets no match before the
/// paragraph ends quotes nothing, which is what stops one stray backtick
/// from reaching forward past every blank line for a partner and quoting
/// everything in between. Lines that are not prose are left empty: there
/// the marks are the shell's, not markdown's.
pub fn code_spans_by_line(lines: &[String], prose: &[bool]) -> Vec<Vec<(usize, usize)>> {
    let mut spans: Vec<Vec<(usize, usize)>> = vec![Vec::new(); lines.len()];
    let paragraph = |at: usize| prose[at] && !lines[at].trim().is_empty();
    let mut from = 0;
    while from < lines.len() {
        if !paragraph(from) {
            from += 1;
            continue;
        }
        let mut to = from;
        while to + 1 < lines.len() && paragraph(to + 1) {
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
