//! How far a run of backticks reaches, so a switch quoted by a code span
//! is told from one standing in the open.
//!
//! Both answers are markdown's own, read off `pulldown-cmark`'s events.
//! A span's reach is settled by every construct in the language at once —
//! a table cell, a link reference definition, an HTML block, a list
//! item's content column, a tab's expanded width, an autolink holding a
//! backtick — and a walk written here is correct for the shapes it models
//! and silently wrong for the rest. The failure direction is fail-open in
//! a safety score: an unmodelled boundary lets two backticks pair across
//! it, and a switch standing between them is scored as a mention rather
//! than as a use.
//!
//! Which dialect is read is its own decision, and a security one:
//! [`EXTENSIONS`] says why, and why the list is short.

use std::ops::Range;

use pulldown_cmark::{Event, Options, Parser};

/// The markdown this reading is of: CommonMark, plus tables. A table's
/// header and delimiter rows open a block together, and each cell is a
/// leaf block of its own, so a reader without them pairs backticks across
/// a cell boundary and quotes text no reader sees quoted.
///
/// **An extension is a security decision here, not a fidelity one.** Every
/// one of them can turn an indented code block into prose, and inside a
/// code block a backtick is the shell's own character while in prose it
/// pairs into a span — so a construct that buys an extension its boundary
/// also buys an attacker a line that stops a switch counting. Footnotes
/// are the worked example and the reason this list is one long: under
/// `ENABLE_FOOTNOTES`, `[^a]: note` above an indented block makes the
/// block that definition's prose, and one line at the top of a document
/// cleared every switch below it. No file in this repository defines a
/// footnote, so the option bought nothing and cost that. Tables earn
/// their place on use — the shipped tree is full of them — and their
/// boundary moves toward reporting rather than away from it.
///
/// So an option goes on only where the tree shows the construct in use and
/// the reading it buys does not quiet a switch. Strikethrough, task lists
/// and math each fail the first test and change no boundary anyway.
const EXTENSIONS: Options = Options::ENABLE_TABLES;

/// The code spans of each line of `text`, as byte ranges local to its own
/// line. A run of backticks may close on a later line, so the lines are
/// read together rather than one at a time: a line a span crosses whole is
/// quoted for its whole length.
///
/// A span is where markdown puts one and nowhere else. A backtick inside a
/// code block, an HTML block, an autolink or a link destination is a byte
/// of that construct rather than a delimiter, and a run that meets no
/// match before its block ends quotes nothing — which is what stops one
/// stray backtick from reaching forward for a partner and quoting
/// everything in between.
pub fn code_spans_by_line(text: &str) -> Vec<Vec<(usize, usize)>> {
    let lines = line_spans(text);
    let mut spans: Vec<Vec<(usize, usize)>> = vec![Vec::new(); lines.len()];
    for (event, span) in Parser::new_ext(text, EXTENSIONS).into_offset_iter() {
        if !matches!(event, Event::Code(_)) {
            continue;
        }
        for at in reached(&lines, &span) {
            let (start, end) = lines[at];
            spans[at].push((span.start.max(start) - start, span.end.min(end) - start));
        }
    }
    spans
}

/// Which lines a byte range reaches, as an index range into `lines`.
///
/// A blank line is a byte range of no width, and one standing inside a
/// code block has to count as reached — it is a line of the block's own
/// text. So a line is reached where it starts before the range ends and
/// ends past where the range starts, which admits a zero-width line
/// inside the range and leaves out the one at its end.
///
/// Nothing is reached by ending exactly where the range starts, so the
/// one comparison serves a code block and a code span alike. A block's
/// range starts at or after the first byte of the line it opens on — a
/// fence's marker or an indented run's first content byte, and a fence
/// may open partway along a line, as the one after a list marker does —
/// and every earlier line ends before that line begins. A span's range
/// starts on a backtick, which is nobody's line ending.
///
/// `lines` is sorted and disjoint, so the lines reached are one run and
/// each end of it is a search rather than a scan. A scan costs every line
/// for every range, which over a document of many small blocks is
/// quadratic in the whole document rather than in one block.
fn reached(lines: &[(usize, usize)], range: &Range<usize>) -> Range<usize> {
    let from = lines.partition_point(|(_, end)| *end <= range.start);
    let to = lines.partition_point(|(start, _)| *start < range.end);
    from..to.max(from)
}

/// Each line of `text` as a byte range of `text` itself, one range per line
/// `str::lines` yields and in its order. The range ends before the line's
/// terminator, and before the `\r` of a `\r\n` — that byte is not part of
/// the line, and a caller indexing the line by these offsets would be one
/// out on every line after the first if it were.
fn line_spans(text: &str) -> Vec<(usize, usize)> {
    let mut spans = Vec::new();
    let mut start = 0;
    for (at, byte) in text.bytes().enumerate() {
        if byte != b'\n' {
            continue;
        }
        let end = match at > start && text.as_bytes()[at - 1] == b'\r' {
            true => at - 1,
            false => at,
        };
        spans.push((start, end));
        start = at + 1;
    }
    if start < text.len() {
        spans.push((start, text.len()));
    }
    spans
}

#[cfg(test)]
mod tests {
    use super::{code_spans_by_line, line_spans};

    /// The two readings are handed to callers that zip them against
    /// `str::lines`, so a range list one line short or one line long
    /// silently pairs every line below it with another line's answer.
    /// Each ending is checked: none, one, a run, and the `\r` that
    /// `str::lines` takes off but the byte offsets still carry.
    #[test]
    fn every_line_gets_one_range_holding_its_own_bytes() {
        for text in [
            "",
            "one",
            "one\n",
            "one\ntwo",
            "one\n\n\ntwo\n",
            "one\r\ntwo\r\n",
            "\r\n",
        ] {
            let spans = line_spans(text);
            let lines: Vec<&str> = text.lines().collect();
            assert_eq!(spans.len(), lines.len(), "{text:?}");
            for (line, (start, end)) in lines.iter().zip(&spans) {
                assert_eq!(&text[*start..*end], *line, "{text:?}");
            }
            assert_eq!(code_spans_by_line(text).len(), lines.len(), "{text:?}");
        }
    }

    /// `reached` narrows to a run by two searches rather than by reading
    /// every line, which is what keeps a document of many small blocks
    /// linear. A search is only sound while the run really is contiguous,
    /// so this holds it against the filter it replaced — the same
    /// predicate, read line by line — over every byte range of a document
    /// carrying each shape the two callers hand it: a fence, an indented
    /// run, blank lines inside a block and outside one, a span crossing a
    /// newline, and a fence opened partway along a list marker's line.
    #[test]
    fn the_lines_a_range_reaches_are_the_lines_that_pass_the_filter() {
        let text = concat!(
            "para `one` two\n\n    indented\n\n    more\n\nafter\n\n",
            "```sh\n\ngit commit\n```\n\n",
            "- ```\n  held\n  ```\n\n",
            "say `git commit\n--no-verify` now\n"
        );
        let lines = super::line_spans(text);
        for start in 0..=text.len() {
            for end in start..=text.len() {
                let range = start..end;
                let want: Vec<usize> = lines
                    .iter()
                    .enumerate()
                    .filter(|(_, (from, to))| *from < range.end && *to > range.start)
                    .map(|(at, _)| at)
                    .collect();
                let got: Vec<usize> = super::reached(&lines, &range).collect();
                assert_eq!(got, want, "{range:?}");
            }
        }
    }

    /// A span crossing a newline is quoted on both lines, each range
    /// local to its own line and stopping at that line's last byte. A
    /// `\r\n` is the case that tells a local offset from a global one.
    #[test]
    fn a_span_crossing_a_newline_is_cut_at_each_line_it_holds() {
        assert_eq!(
            code_spans_by_line("say `git commit\n--no-verify` now\n"),
            vec![vec![(4, 15)], vec![(0, 12)]]
        );
        assert_eq!(
            code_spans_by_line("say `git commit\r\n--no-verify` now\r\n"),
            vec![vec![(4, 15)], vec![(0, 12)]]
        );
    }
}
