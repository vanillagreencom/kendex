//! One glyph per meaning, and the ASCII a terminal without a UTF-8 locale
//! gets in its place. No emoji: their width differs between terminals, and
//! a column that drifts by one cell per row is the thing a layout exists to
//! prevent.

/// A meaning a line can carry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Symbol {
    Done,
    /// Failed, or blocked.
    Failed,
    /// Needs a decision from the reader.
    Decision,
    Notice,
    /// A safety finding at critical, the ramp's full mark.
    Critical,
    /// A safety finding at high.
    High,
    /// A safety finding at medium or low, the ramp's empty mark.
    Low,
    /// From one value to another.
    Change,
    /// The choice the cursor is on, and a folded block.
    Current,
    /// A rule under a table header, one cell of it.
    Separator,
    /// Between two choices on one line.
    Divider,
}

/// Which set the glyphs come from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Glyphs {
    Unicode,
    Ascii,
}

impl Symbol {
    pub fn glyph(self, glyphs: Glyphs) -> &'static str {
        match (self, glyphs) {
            (Symbol::Done, Glyphs::Unicode) => "✓",
            (Symbol::Done, Glyphs::Ascii) => "v",
            (Symbol::Failed, Glyphs::Unicode) => "✗",
            (Symbol::Failed, Glyphs::Ascii) => "x",
            (Symbol::Decision, _) => "!",
            (Symbol::Notice, Glyphs::Unicode) => "•",
            (Symbol::Notice, Glyphs::Ascii) => "*",
            (Symbol::Critical, Glyphs::Unicode) => "◉",
            (Symbol::Critical, Glyphs::Ascii) => "#",
            (Symbol::High, Glyphs::Unicode) => "◐",
            (Symbol::High, Glyphs::Ascii) => "+",
            (Symbol::Low, Glyphs::Unicode) => "○",
            (Symbol::Low, Glyphs::Ascii) => "o",
            (Symbol::Change, Glyphs::Unicode) => "→",
            (Symbol::Change, Glyphs::Ascii) => "->",
            (Symbol::Current, Glyphs::Unicode) => "›",
            (Symbol::Current, Glyphs::Ascii) => ">",
            (Symbol::Separator, Glyphs::Unicode) => "─",
            (Symbol::Separator, Glyphs::Ascii) => "-",
            (Symbol::Divider, Glyphs::Unicode) => "·",
            (Symbol::Divider, Glyphs::Ascii) => "|",
        }
    }
}

/// The glyph set a locale can show. The first of `LC_ALL`, `LC_CTYPE` and
/// `LANG` that is set and not empty is the one in force, which is the
/// order a C library reads them in; with none set the locale is `C`, and
/// `C` is ASCII.
pub(super) fn for_locale(
    lc_all: Option<&str>,
    lc_ctype: Option<&str>,
    lang: Option<&str>,
) -> Glyphs {
    let locale = [lc_all, lc_ctype, lang]
        .into_iter()
        .flatten()
        .find(|value| !value.is_empty())
        .unwrap_or("C")
        .to_ascii_lowercase();
    match locale.contains("utf-8") || locale.contains("utf8") {
        true => Glyphs::Unicode,
        false => Glyphs::Ascii,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Each meaning's glyph in both sets. The ASCII column is plain
    /// printable bytes, so a C locale draws every one of them.
    #[test]
    fn each_meaning_has_one_glyph_and_an_ascii_fallback() {
        let rows = [
            (Symbol::Done, "✓", "v"),
            (Symbol::Failed, "✗", "x"),
            (Symbol::Decision, "!", "!"),
            (Symbol::Notice, "•", "*"),
            (Symbol::Critical, "◉", "#"),
            (Symbol::High, "◐", "+"),
            (Symbol::Low, "○", "o"),
            (Symbol::Change, "→", "->"),
            (Symbol::Current, "›", ">"),
            (Symbol::Separator, "─", "-"),
            (Symbol::Divider, "·", "|"),
        ];
        for (symbol, unicode, ascii) in rows {
            assert_eq!(symbol.glyph(Glyphs::Unicode), unicode, "{symbol:?}");
            assert_eq!(symbol.glyph(Glyphs::Ascii), ascii, "{symbol:?}");
            assert!(ascii.is_ascii(), "{symbol:?}");
        }
    }

    /// The first non-empty variable decides, in the C library's order.
    #[test]
    fn the_locale_in_force_picks_the_set() {
        /// `LC_ALL`, `LC_CTYPE` and `LANG`, and the set they pick.
        type Row = (
            Option<&'static str>,
            Option<&'static str>,
            Option<&'static str>,
            Glyphs,
        );
        let rows: [Row; 7] = [
            (None, None, Some("en_US.UTF-8"), Glyphs::Unicode),
            (None, None, Some("C.utf8"), Glyphs::Unicode),
            (None, None, None, Glyphs::Ascii),
            (None, None, Some("C"), Glyphs::Ascii),
            (Some("C"), None, Some("en_US.UTF-8"), Glyphs::Ascii),
            (Some(""), Some("en_US.UTF-8"), Some("C"), Glyphs::Unicode),
            (None, Some("POSIX"), Some("en_US.UTF-8"), Glyphs::Ascii),
        ];
        for (lc_all, lc_ctype, lang, want) in rows {
            assert_eq!(
                for_locale(lc_all, lc_ctype, lang),
                want,
                "LC_ALL={lc_all:?} LC_CTYPE={lc_ctype:?} LANG={lang:?}"
            );
        }
    }
}
