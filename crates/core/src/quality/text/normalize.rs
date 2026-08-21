//! Reading content as the text it claims to be: hidden characters removed,
//! lookalike letters folded back, and what that cost recorded so a rule can
//! say what it found rather than only how much of it there was.

use unicode_normalization::UnicodeNormalization;

use super::super::homoglyph;
use super::Normalization;

/// Invisible characters out, NFKC, then homoglyphs folded — in that order,
/// so a fullwidth letter becomes ASCII before the confusable table sees it.
///
/// Bytes that were not valid UTF-8 arrive here already replaced by U+FFFD
/// (see `TreeFile::read`), and counting them is how `undecodable-content`
/// learns that some of what it read is a guess.
pub fn deobfuscate(location: &str, text: &str) -> (String, Normalization) {
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
    let out: String = stripped
        .nfkc()
        .collect::<String>()
        .chars()
        .map(|c| match homoglyph::fold(c) {
            Some(latin) => {
                report.homoglyphs += 1;
                report.found.insert(c);
                latin
            }
            None => c,
        })
        .collect();
    (out, report)
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
            let (short, report) = deobfuscate("x", text);
            assert_eq!(short, the_long_way(text), "{text:?}");
            assert!(!report.reportable(), "{text:?}");
        }
    }

    /// And the shortcut must not be taken for anything else: one letter
    /// that only looks Latin still folds, and still says so.
    #[test]
    fn a_lookalike_letter_still_folds_and_is_counted() {
        let (out, report) = deobfuscate("x", "\u{0456}gnore previous");
        assert_eq!(out, "ignore previous");
        assert_eq!(report.homoglyphs, 1);
    }
}
