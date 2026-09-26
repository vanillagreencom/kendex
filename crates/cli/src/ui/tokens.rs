//! The colour roles a verb paints with, and the two palettes they map to.
//!
//! A component names a role, never a colour, so the whole CLI changes
//! colour in this file. The default palette is the terminal's own ANSI 16,
//! which keeps the reader's theme in charge of what each role looks like;
//! a terminal that says it draws truecolor gets the app's own values, so
//! the CLI and the app read as one product.
//!
//! The only escape sequences the CLI writes are composed here and in
//! [`super::components`]'s hyperlink. `tools/guard`'s `cli-raw-output`
//! lane refuses one spelled anywhere else under `crates/cli/src/`.

/// A colour role.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Token {
    /// The verb, a key to press, a recommended choice.
    Accent,
    Ok,
    Warn,
    Danger,
    Info,
    /// Counts, targets, ages: what a reader may skip.
    Muted,
    /// Weight without colour: the terminal's own foreground, bold.
    Emphasis,
}

/// How a role becomes a colour.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Palette {
    /// The terminal's 16 colours, whatever its theme makes of them.
    Ansi16,
    /// The app's values, for a terminal that sets `COLORTERM=truecolor`.
    Truecolor,
}

impl Token {
    /// The app stylesheet variable this role takes its truecolor value
    /// from, and that value: `ui/src/index.css`'s `.dark` block, converted
    /// from oklch to sRGB. The dark theme's values, because they are the
    /// ones drawn to read on a dark background, which is what most
    /// terminals are. `the_app_palette_is_the_stylesheets` derives every
    /// value again from the stylesheet itself.
    pub(super) fn app(self) -> Option<(&'static str, [u8; 3])> {
        match self {
            Token::Accent => Some(("primary", [2, 111, 215])),
            Token::Ok => Some(("good", [34, 195, 115])),
            Token::Warn => Some(("warning", [228, 158, 34])),
            Token::Danger => Some(("critical", [226, 73, 71])),
            Token::Info => Some(("info", [57, 134, 228])),
            Token::Muted => Some(("muted-foreground", [153, 159, 168])),
            Token::Emphasis => None,
        }
    }

    fn ansi16(self) -> Option<u8> {
        match self {
            Token::Accent => Some(34),
            Token::Ok => Some(32),
            Token::Warn => Some(33),
            Token::Danger => Some(31),
            Token::Info => Some(36),
            Token::Muted => Some(90),
            Token::Emphasis => None,
        }
    }

    /// The select graphic rendition parameters that switch this role on,
    /// bold first where it is asked for.
    fn sgr(self, palette: Palette, bold: bool) -> String {
        let colour = match palette {
            Palette::Ansi16 => self.ansi16().map(|code| code.to_string()),
            Palette::Truecolor => self.app().map(|(_, [r, g, b])| format!("38;2;{r};{g};{b}")),
        };
        let bold = bold || self == Token::Emphasis;
        match (bold, colour) {
            (true, Some(colour)) => format!("1;{colour}"),
            (true, None) => "1".to_owned(),
            (false, Some(colour)) => colour,
            // Only Emphasis has no colour, and it is always bold.
            (false, None) => unreachable!("a role with no colour is always bold"),
        }
    }
}

/// `text` in `token`'s colour. Text is escaped before it gets here: the
/// components take raw values and escape them first, so the one control
/// sequence this can put on the line is its own.
pub(super) fn paint(palette: Palette, token: Token, text: &str) -> String {
    styled(palette, token, false, text)
}

/// `text` in `token`'s colour, bold.
pub(super) fn strong(palette: Palette, token: Token, text: &str) -> String {
    styled(palette, token, true, text)
}

fn styled(palette: Palette, token: Token, bold: bool, text: &str) -> String {
    match text.is_empty() {
        true => String::new(),
        false => format!("\x1b[{}m{text}\x1b[0m", token.sgr(palette, bold)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const ROLES: [Token; 7] = [
        Token::Accent,
        Token::Ok,
        Token::Warn,
        Token::Danger,
        Token::Info,
        Token::Muted,
        Token::Emphasis,
    ];

    /// Each role's escape in both palettes, and bold on top of either.
    #[test]
    fn each_role_paints_its_own_escape() {
        let rows: [(Token, &str, &str); 7] = [
            (Token::Accent, "34", "38;2;2;111;215"),
            (Token::Ok, "32", "38;2;34;195;115"),
            (Token::Warn, "33", "38;2;228;158;34"),
            (Token::Danger, "31", "38;2;226;73;71"),
            (Token::Info, "36", "38;2;57;134;228"),
            (Token::Muted, "90", "38;2;153;159;168"),
            (Token::Emphasis, "1", "1"),
        ];
        for (token, ansi, truecolor) in rows {
            assert_eq!(
                paint(Palette::Ansi16, token, "x"),
                format!("\x1b[{ansi}mx\x1b[0m"),
                "{token:?}"
            );
            assert_eq!(
                paint(Palette::Truecolor, token, "x"),
                format!("\x1b[{truecolor}mx\x1b[0m"),
                "{token:?}"
            );
        }
        assert_eq!(
            strong(Palette::Ansi16, Token::Ok, "x"),
            "\x1b[1;32mx\x1b[0m"
        );
        assert_eq!(paint(Palette::Ansi16, Token::Ok, ""), "");
    }

    /// The truecolor values are the app's: every role that has one names
    /// a variable in the stylesheet's dark block, and its value is that
    /// variable's oklch converted to sRGB here, from the file the app
    /// builds with. A changed app colour fails this until the table
    /// follows it.
    #[test]
    fn the_app_palette_is_the_stylesheets() {
        let css = include_str!("../../../../ui/src/index.css");
        let dark = css
            .split_once(".dark {")
            .and_then(|(_, rest)| rest.split_once('}'))
            .map(|(block, _)| block)
            .unwrap_or_default();
        let coloured: Vec<(&str, [u8; 3])> = ROLES.into_iter().filter_map(Token::app).collect();
        assert_eq!(
            coloured.len(),
            6,
            "every role but emphasis takes an app colour"
        );
        for (variable, rgb) in coloured {
            let declared = dark
                .lines()
                .find_map(|line| line.trim().strip_prefix(&format!("--{variable}: oklch(")))
                .and_then(|rest| rest.strip_suffix(");"))
                .unwrap_or_else(|| panic!("--{variable} has no oklch value in the .dark block"));
            let parts: Vec<f64> = declared
                .split_whitespace()
                .map(|part| part.parse().unwrap_or(f64::NAN))
                .collect();
            let [l, c, h] = parts[..] else {
                panic!("--{variable} is not three numbers: {declared}")
            };
            assert_eq!(oklch_to_srgb(l, c, h), rgb, "--{variable}");
        }
    }

    /// Björn Ottosson's OKLab to linear sRGB, then the sRGB transfer curve.
    fn oklch_to_srgb(l: f64, c: f64, h: f64) -> [u8; 3] {
        let (a, b) = (c * h.to_radians().cos(), c * h.to_radians().sin());
        let l_ = (l + 0.396_337_777_4 * a + 0.215_803_757_3 * b).powi(3);
        let m_ = (l - 0.105_561_345_8 * a - 0.063_854_172_8 * b).powi(3);
        let s_ = (l - 0.089_484_177_5 * a - 1.291_485_548 * b).powi(3);
        let linear = [
            4.076_741_662_1 * l_ - 3.307_711_591_3 * m_ + 0.230_969_929_2 * s_,
            -1.268_438_004_6 * l_ + 2.609_757_401_1 * m_ - 0.341_319_396_5 * s_,
            -0.004_196_086_3 * l_ - 0.703_418_614_7 * m_ + 1.707_614_701 * s_,
        ];
        linear.map(|v| {
            let v = v.clamp(0.0, 1.0);
            let encoded = match v <= 0.003_130_8 {
                true => 12.92 * v,
                false => 1.055 * v.powf(1.0 / 2.4) - 0.055,
            };
            (encoded * 255.0).round() as u8
        })
    }
}
