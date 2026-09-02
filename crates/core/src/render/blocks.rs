//! Where a document's code is: how far a run of backticks reaches, and
//! which lines a code block covers.
//!
//! Two callers ask, and they ask for different reasons. The safety audit
//! tells a switch quoted by a code span from one standing in the open. The
//! prose rewrite leaves every byte of a code sample as the author wrote
//! it, so it needs the blocks as well as the spans.
//!
//! Both answers are markdown's own, read off `pulldown-cmark`'s events.
//! A span's reach is settled by every construct in the language at once —
//! a table cell, a link reference definition, an HTML block, a list
//! item's content column, a tab's expanded width, an autolink holding a
//! backtick — and a walk written here is correct for the shapes it models
//! and silently wrong for the rest. Each caller fails a different way for
//! it: the audit fail-open in a safety score, where an unmodelled boundary
//! lets two backticks pair across it and a switch between them is scored
//! as a mention rather than as a use; the rewrite by editing bytes inside
//! a sample an agent was meant to copy verbatim. So one reading answers
//! both rather than each keeping its own.
//!
//! Which dialect is read is its own decision, and a security one:
//! [`EXTENSIONS`] says why, and why the list is short.

use std::ops::Range;

use pulldown_cmark::{Event, Options, Parser, Tag};

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
///
/// The prose rewrite reads the same list and has its own stake in it: an
/// option that turns a block into prose costs the rewrite the block's
/// bytes, which it would otherwise have left as the author wrote them. It
/// wants the same options for the opposite reason, and the audit's test is
/// the stricter one, so this list is settled by the audit alone — an option
/// the rewrite would want is still refused if it can quiet a switch.
const EXTENSIONS: Options = Options::ENABLE_TABLES;

/// A document's code, line by line. Both vectors carry one entry per line
/// `str::lines` yields, in its order, so a caller zips either against the
/// lines it already has.
///
/// `str::split_inclusive('\n')` yields the same count over the same text —
/// it differs only in keeping each terminator — so a caller holding its
/// lines that way indexes these by the same position. The prose rewrite
/// needs the terminators and relies on that.
pub struct Code {
    /// The code spans of each line, as byte ranges local to its own line.
    pub spans: Vec<Vec<(usize, usize)>>,
    /// Whether markdown reads the line as something other than prose: a
    /// code block, fenced or indented, or a raw HTML block. Where any of
    /// those starts and stops is the parser's answer, and this field is how
    /// a caller gets it without asking again — so the answer is not written
    /// out here as well, where it could drift from the one that ships.
    /// [`reached`] is where a range becomes a set of lines.
    ///
    /// The prose rewrite pays for the raw-HTML half in silence: a tool
    /// reference inside such a block keeps Claude's words and no warning
    /// names it, because the line was never read. Left as authored is the
    /// safe direction, but not a reported one — as the `SKILL.md` skip in
    /// `rewrite_prose` is not either.
    pub block: Vec<bool>,
}

/// Where `text` keeps its code. A run of backticks may close on a later
/// line and a block runs over many, so the lines are read together rather
/// than one at a time: a line a span crosses whole is quoted for its whole
/// length.
///
/// A span is where markdown puts one and nowhere else. A backtick inside a
/// code block, an HTML block, an autolink or a link destination is a byte
/// of that construct rather than a delimiter, and a run that meets no
/// match before its block ends quotes nothing — which is what stops one
/// stray backtick from reaching forward for a partner and quoting
/// everything in between.
///
/// A raw HTML block counts with the code blocks, because inside one
/// markdown reads nothing: a fence there is three literal backticks and a
/// span is two, so a reader that took those lines for prose would find no
/// marks on a sample and rewrite straight through it.
///
/// Where such a block starts and stops is markdown's answer too, and one
/// worth leaving to it: which shapes open one, and what closes each, is
/// not a rule short enough to restate. The reach is what a caller feels,
/// and it can run far past what the author meant, unwarned.
pub fn code_by_line(text: &str) -> Code {
    let lines = line_spans(text);
    let mut code = Code {
        spans: vec![Vec::new(); lines.len()],
        block: vec![false; lines.len()],
    };
    for (event, span) in Parser::new_ext(text, EXTENSIONS).into_offset_iter() {
        match event {
            Event::Code(_) => {
                for at in reached(&lines, &span) {
                    let (start, end) = lines[at];
                    code.spans[at].push((span.start.max(start) - start, span.end.min(end) - start));
                }
            }
            Event::Start(Tag::CodeBlock(_) | Tag::HtmlBlock) => {
                for at in reached(&lines, &span) {
                    code.block[at] = true;
                }
            }
            _ => {}
        }
    }
    code
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
/// and every earlier line ends before that line begins. A fenced range
/// ends past its closing run, so both marker lines fall inside it. A
/// span's range starts on a backtick, which is nobody's line ending.
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
    use super::{code_by_line, line_spans};

    /// The two readings are handed to callers that zip them against
    /// `str::lines` or against `str::split_inclusive`, so a range list one
    /// line short or one line long silently pairs every line below it with
    /// another line's answer. Both splits are checked, which is the
    /// equivalence [`Code`](super::Code) states. Each ending is covered:
    /// none, one, a run, and the `\r` that `str::lines` takes off but the
    /// byte offsets still carry.
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
            assert_eq!(text.split_inclusive('\n').count(), spans.len(), "{text:?}");
            for (line, (start, end)) in lines.iter().zip(&spans) {
                assert_eq!(&text[*start..*end], *line, "{text:?}");
            }
            let code = code_by_line(text);
            assert_eq!(code.spans.len(), lines.len(), "{text:?}");
            assert_eq!(code.block.len(), lines.len(), "{text:?}");
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

    /// `block` is what the prose rewrite copies without looking, so its
    /// geometry is pinned directly rather than through a rewrite outcome:
    /// a fence covers its own two marker lines and the blank line between
    /// them, and an indented run covers the blank line it holds but not
    /// the one that ended it.
    ///
    /// The `<div>` is the raw-HTML case, and what it pins is that the
    /// block reaches past its closing tag — not any rule for where one
    /// ends, which is the parser's.
    #[test]
    fn a_block_covers_its_own_lines_and_stops() {
        let text = concat!(
            "intro\n",        // 0
            "\n",             // 1
            "```sh\n",        // 2
            "\n",             // 3
            "git commit\n",   // 4
            "```\n",          // 5
            "\n",             // 6
            "    indented\n", // 7
            "\n",             // 8
            "    more\n",     // 9
            "\n",             // 10
            "after\n",        // 11
            "<div>\n",        // 12
            "held\n",         // 13
            "</div>\n",       // 14
            "still held\n",   // 15
            "\n",             // 16
            "out\n",          // 17
        );
        assert_eq!(
            code_by_line(text).block,
            vec![
                false, false, true, true, true, true, false, true, true, true, false, false, true,
                true, true, true, false, false,
            ]
        );
    }

    /// A span crossing a newline is quoted on both lines, each range
    /// local to its own line and stopping at that line's last byte. A
    /// `\r\n` is the case that tells a local offset from a global one.
    #[test]
    fn a_span_crossing_a_newline_is_cut_at_each_line_it_holds() {
        assert_eq!(
            code_by_line("say `git commit\n--no-verify` now\n").spans,
            vec![vec![(4, 15)], vec![(0, 12)]]
        );
        assert_eq!(
            code_by_line("say `git commit\r\n--no-verify` now\r\n").spans,
            vec![vec![(4, 15)], vec![(0, 12)]]
        );
    }
}
