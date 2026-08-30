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

/// Whether a block boundary falls between two prose lines. A run of
/// backticks reaches only as far as the block it opened in, and this is
/// what stops one at the edge.
///
/// Four shapes draw a boundary. An ATX heading is one line and a block of
/// its own, so a boundary falls on both sides of it. A setext underline
/// closes the heading whose text stands above it, so a boundary falls
/// after it. A list marker opens an item, which is a block of its own,
/// while a line carrying no marker continues the item above it. A
/// blockquote is a block whether or not a blank line precedes it, so a
/// quoted line and a plain one are never the same block.
///
/// Nothing else here is a container. A table row, an HTML block and a
/// footnote definition each end a paragraph in markdown and do not end
/// one here.
fn breaks_a_block(above: &str, below: &str) -> bool {
    atx_heading(above)
        || setext_underline(above)
        || atx_heading(below)
        || setext_underline(below)
        || list_marker(below)
        || quoted(above) != quoted(below)
}

/// What stands past up to three spaces of indent, or `None` at four,
/// where markdown reads an indented block rather than a marker.
fn unindented(line: &str) -> Option<&str> {
    let rest = line.trim_start_matches(' ');
    (line.len() - rest.len() <= 3).then_some(rest)
}

/// One to six `#`, then whitespace or the end of the line.
fn atx_heading(line: &str) -> bool {
    let Some(rest) = unindented(line) else {
        return false;
    };
    let hashes = rest.bytes().take_while(|b| *b == b'#').count();
    (1..=6).contains(&hashes)
        && rest[hashes..]
            .chars()
            .next()
            .is_none_or(char::is_whitespace)
}

/// Nothing but `=` or nothing but `-`. A run of dashes with no paragraph
/// above it is a thematic break rather than an underline, and both are
/// blocks, so one reading answers for both.
fn setext_underline(line: &str) -> bool {
    let Some(rest) = unindented(line).map(str::trim_end) else {
        return false;
    };
    !rest.is_empty() && (rest.bytes().all(|b| b == b'=') || rest.bytes().all(|b| b == b'-'))
}

/// A list item's marker: `-`, `+` or `*`, or up to nine digits and a `.`
/// or `)`, then whitespace or the end of the line. The whitespace is what
/// tells a marker from the `--no-verify` that opens a line of prose.
fn list_marker(line: &str) -> bool {
    let Some(rest) = unindented(line) else {
        return false;
    };
    let after = match rest.as_bytes() {
        [b'-' | b'+' | b'*', tail @ ..] => tail,
        bytes => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            match bytes.get(digits) {
                Some(b'.' | b')') if (1..=9).contains(&digits) => &bytes[digits + 1..],
                _ => return false,
            }
        }
    };
    after.first().is_none_or(u8::is_ascii_whitespace)
}

/// Whether this line stands inside a blockquote.
fn quoted(line: &str) -> bool {
    unindented(line).is_some_and(|rest| rest.starts_with('>'))
}

/// Whether the byte at `at` is one a backslash made literal. Backslashes
/// escape each other, so it is the run of them ending at `at` that
/// decides: an odd run leaves the byte escaped, an even one leaves it a
/// delimiter with escaped backslashes in front of it.
fn escaped(bytes: &[u8], at: usize) -> bool {
    let before = bytes[..at].iter().rev();
    before.take_while(|b| **b == b'\\').count() % 2 == 1
}

/// Inline code spans of one line, as outer byte ranges. A run of backticks
/// closes only on a run of the same length, so a span may quote backticks
/// of its own, and a run that never meets its match is the literal
/// characters rather than an opener — which is what keeps one stray
/// backtick from reading the rest of a document as quoted.
///
/// A backslash-escaped backtick opens nothing: it is the character the
/// text wanted to show. It still closes, because markdown reads no
/// escapes inside a span — a backslash there is one more byte of the code
/// being quoted.
pub fn code_spans(line: &str) -> Vec<(usize, usize)> {
    let bytes = line.as_bytes();
    let mut spans: Vec<(usize, usize)> = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        if bytes[at] != b'`' {
            at += 1;
            continue;
        }
        if escaped(bytes, at) {
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
/// The reach is one block — a run of `prose` lines with no blank line and
/// no boundary among them — not the whole document. A run that meets no
/// match before the block ends quotes nothing, which is what stops one
/// stray backtick from reaching forward for a partner and quoting
/// everything in between. A blank line is not the only thing that ends a
/// block: [`breaks_a_block`] says where else one ends, and a run reaching
/// across such a boundary would pair two backticks markdown reads as
/// literal characters and quote a whole line nobody quoted. Lines that are
/// not prose are left empty: there the marks are the shell's, not
/// markdown's.
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
        while to + 1 < lines.len()
            && paragraph(to + 1)
            && !breaks_a_block(&lines[to], &lines[to + 1])
        {
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
