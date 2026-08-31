//! What a line's code marks are: the fence that opens or closes a block,
//! and the inline spans a run of backticks quotes, each read from that
//! line alone.
//!
//! This is the prose rewrite's reader and nothing else's. The audit's
//! reading of the same marks is [`super::blocks`], which asks a markdown
//! parser rather than a line, so the two do not agree on every document
//! and are not meant to: what a rewrite may safely leave alone is a
//! narrower question than where a span really reaches.

/// A fence line: any leading whitespace, then three or more backticks or
/// tildes. `bare` — nothing but whitespace after the run — is what makes a
/// line eligible to close a fence rather than open one.
///
/// A backtick fence's info string may hold no backtick. Markdown reads
/// ``` ``` aa ``` ``` as a paragraph carrying a code span, not as a block
/// that swallows everything under it, and a reader that opens a fence
/// there loses the spans of every line the paragraph really holds. The
/// limit is the marker's own: a tilde fence's info string may hold
/// backticks and tildes alike, so this is asked of one marker rather than
/// of info strings in general.
///
/// Indent is not a limit. Markdown allows three spaces at the top level, but
/// a block nested inside a list item starts four in, and that is the common
/// shape in a real skill: a scanner that stops at three reads the block as
/// prose and cuts or rewrites straight through it.
pub fn fence_marker(line: &str) -> Option<(char, usize, bool)> {
    let rest = line.trim_start();
    let marker = rest.chars().next().filter(|c| matches!(c, '`' | '~'))?;
    let run = rest.chars().take_while(|c| *c == marker).count();
    let info = &rest[run..];
    if marker == '`' && info.contains('`') {
        return None;
    }
    (run >= 3).then(|| (marker, run, info.trim().is_empty()))
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
