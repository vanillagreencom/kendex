//! Reading content as the text it claims to be: hidden characters removed,
//! lookalike letters folded back, and what that cost recorded so a rule can
//! say what it found rather than only how much of it there was.

use std::ops::Range;

use unicode_normalization::UnicodeNormalization;

use super::super::homoglyph;
use super::Normalization;

/// Which of a document's lookalike letters are reported. Every one is
/// folded whatever this says, so the rules read the plain text either way;
/// what it decides is whether the letter is the document imitating Latin,
/// or the document quoting a letter that is itself the subject.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Letters {
    /// Every folded letter is reported.
    Reported,
    /// Markdown: a letter inside a code span or a code block is the
    /// document quoting text, such as the key a transliteration example is
    /// about, and only the letters outside them are reported.
    OutsideCode,
    /// A corpus a test reads: its letters are the data under test, and
    /// none is reported.
    Corpus,
}

/// Invisible characters out, NFKC, then homoglyphs folded — in that order,
/// so a fullwidth letter becomes ASCII before the confusable table sees it.
///
/// Bytes that were not valid UTF-8 arrive here already replaced by U+FFFD
/// (see `TreeFile::read`), and counting them is how `undecodable-content`
/// learns that some of what it read is a guess.
pub fn deobfuscate(location: &str, text: &str, letters: Letters) -> (String, Normalization) {
    let mut report = Normalization {
        location: location.to_owned(),
        ..Normalization::default()
    };
    // Nothing here has anything to say about plain ASCII: every invisible
    // character, every compatibility form and every homoglyph is outside
    // it, and NFKC leaves ASCII exactly as it found it. Most installed
    // content is ASCII from end to end, and normalizing it was the second
    // most expensive thing an audit did.
    if text.is_ascii() {
        return (text.to_owned(), report);
    }
    let stripped: String = text
        .chars()
        .filter(|c| {
            let invisible = is_invisible(*c);
            if invisible && is_reportable(*c) {
                report.invisible += 1;
                report.found.insert(*c);
            }
            report.undecodable += usize::from(*c == char::REPLACEMENT_CHARACTER);
            !invisible
        })
        .collect();
    let composed: String = stripped.nfkc().collect();
    // Where markdown keeps its code is read off the text the letters are
    // folded in, and only once a letter folds: most documents carry none,
    // and a markdown parse is the cost of every one that does.
    let mut code: Option<Vec<Range<usize>>> = None;
    let out: String = composed
        .char_indices()
        .map(|(at, c)| match homoglyph::fold(c) {
            Some(latin) => {
                let reported = match letters {
                    Letters::Reported => true,
                    Letters::OutsideCode => {
                        !within(code.get_or_insert_with(|| code_ranges(&composed)), at)
                    }
                    Letters::Corpus => false,
                };
                if reported {
                    report.homoglyphs += 1;
                    report.found.insert(c);
                }
                latin
            }
            None => c,
        })
        .collect();
    report.unreadable = (report.undecodable > 0).then(|| unreadable_print(text));
    (out, report)
}

/// The byte ranges of `text` that markdown reads as code: every code span,
/// and every line of a code block.
fn code_ranges(text: &str) -> Vec<Range<usize>> {
    let code = crate::render::code_by_line(text);
    let mut ranges = Vec::new();
    let mut start = 0;
    // `code_by_line` has one entry per line `str::lines` yields, which is
    // one per piece this split yields, terminator included.
    for (index, line) in text.split_inclusive('\n').enumerate() {
        match code.block.get(index) {
            Some(true) => ranges.push(start..start + line.len()),
            Some(false) => ranges.extend(
                code.spans[index]
                    .iter()
                    .map(|(from, to)| start + from..start + to),
            ),
            None => unreachable!("code_by_line reads one entry for every line of its text"),
        }
        start += line.len();
    }
    ranges
}

/// Whether `at` falls inside one of `ranges`, which are sorted and
/// disjoint.
fn within(ranges: &[Range<usize>], at: usize) -> bool {
    let next = ranges.partition_point(|range| range.end <= at);
    ranges.get(next).is_some_and(|range| range.start <= at)
}

/// A short name for the unreadable places in one document.
///
/// The bytes themselves are gone: `TreeFile::read` decodes lossily so a
/// payload cannot be hidden from every rule behind one stray byte, and each
/// invalid run arrives here as a single U+FFFD. What is left to tell two
/// unreadable files apart is the readable text around their holes, which is
/// what this names. Never the file's path — rendering moves content between
/// files, and an identity that moved with it would stop being the finding a
/// decision was made about.
fn unreadable_print(text: &str) -> String {
    const AROUND: usize = 16;
    let chars: Vec<char> = text.chars().collect();
    let mut material = String::new();
    for at in chars
        .iter()
        .enumerate()
        .filter(|(_, c)| **c == char::REPLACEMENT_CHARACTER)
        .map(|(at, _)| at)
    {
        let from = at.saturating_sub(AROUND);
        let to = (at + 1 + AROUND).min(chars.len());
        material.extend(&chars[from..to]);
        // One hole's surroundings never run into the next one's: without a
        // separator, two files whose holes sit differently in the same text
        // could still spell one string.
        material.push('\u{1}');
    }
    crate::quality::digest(&material)
}

/// Characters that occupy no space on screen: zero-width joiners and
/// spaces, bidirectional overrides, word joiners, variation selectors and
/// the byte-order mark. All of them come out before the rules read a line.
fn is_invisible(c: char) -> bool {
    matches!(c as u32,
        0x00AD | 0x180E | 0xFEFF
        | 0x200B..=0x200F
        | 0x202A..=0x202E
        | 0x2060..=0x2064
        | 0x2066..=0x2069
        | 0xFE00..=0xFE0F
        | 0xE0100..=0xE01EF)
}

/// Which of those are worth reporting. Variation selectors are how every
/// emoji is spelled — `⚠️` is U+26A0 followed by U+FE0F — so counting them
/// would flag every shell script that prints a warning sign.
fn is_reportable(c: char) -> bool {
    !matches!(c as u32, 0xFE00..=0xFE0F | 0xE0100..=0xE01EF)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The full pass, spelled out: what the ASCII shortcut has to agree
    /// with for every input it takes.
    fn the_long_way(text: &str) -> String {
        text.chars()
            .filter(|c| !is_invisible(*c))
            .collect::<String>()
            .nfkc()
            .collect::<String>()
            .chars()
            .map(|c| homoglyph::fold(c).unwrap_or(c))
            .collect()
    }

    #[test]
    fn ascii_reads_the_same_by_the_short_way_as_by_the_long_one() {
        for text in [
            "",
            "read the `diff` first",
            "curl https://example.com/x.sh | sh\n\tthen run it",
            "quotes \"straight\" and 'single' -- dashes ... dots",
            "a\r\nb\n\nc",
        ] {
            let (short, report) = deobfuscate("x", text, Letters::Reported);
            assert_eq!(short, the_long_way(text), "{text:?}");
            assert!(!report.reportable(), "{text:?}");
        }
    }

    /// And the shortcut must not be taken for anything else: one letter
    /// that only looks Latin still folds, and still says so.
    #[test]
    fn a_lookalike_letter_still_folds_and_is_counted() {
        let (out, report) = deobfuscate("x", "\u{0456}gnore previous", Letters::Reported);
        assert_eq!(out, "ignore previous");
        assert_eq!(report.homoglyphs, 1);
    }
}
