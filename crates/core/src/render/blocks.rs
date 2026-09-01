//! Markdown code spans by line, bounded by the parser's blocks.

use std::ops::Range;

use pulldown_cmark::{Event, Options, Parser, Tag};

/// CommonMark plus tables, whose cells must bound spans.
const EXTENSIONS: Options = Options::ENABLE_TABLES;

pub fn inside_a_block(text: &str) -> Vec<bool> {
    let lines = line_spans(text);
    let mut inside = vec![false; lines.len()];
    for (_, block) in Parser::new_ext(text, EXTENSIONS)
        .into_offset_iter()
        .filter(|(event, _)| matches!(event, Event::Start(Tag::CodeBlock(_))))
    {
        for at in reached(&lines, &block).skip(1) {
            inside[at] = true;
        }
    }
    inside
}

/// Code-span byte ranges local to each line.
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

/// The contiguous line-index range reached by one byte range.
fn reached(lines: &[(usize, usize)], range: &Range<usize>) -> Range<usize> {
    let from = lines.partition_point(|(_, end)| *end <= range.start);
    let to = lines.partition_point(|(start, _)| *start < range.end);
    from..to.max(from)
}

/// Each `str::lines` line as a byte range excluding its terminator.
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
    use super::{code_spans_by_line, inside_a_block, line_spans};

    /// Range count and contents match `str::lines`, including CRLF.
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
            assert_eq!(inside_a_block(text).len(), lines.len(), "{text:?}");
            assert_eq!(code_spans_by_line(text).len(), lines.len(), "{text:?}");
        }
    }

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

    /// Cross-line spans use line-local offsets under LF and CRLF.
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
