//! Which of the three renderings a run gets, read once from the terminal
//! and the environment.
//!
//! **Rich** is a terminal on both streams: colour, glyphs, blank lines
//! between sections, and text wrapped to the terminal's width, never past
//! 100 columns. **Plain** is everything else — a pipe, `NO_COLOR`,
//! `TERM=dumb` — and is the grammar scripts and tests read: one line per
//! thing said, no colour, no cursor control, no wrapping, no header. A
//! plain run is the same whether a terminal is attached or not, so
//! `NO_COLOR` on a terminal prints exactly what a pipe gets. **JSON** is a
//! verb's own flag and goes around the components through
//! [`super::answer`].
//!
//! `KENDEX_UI=plain|pretty` still overrides the terminal detection, the way
//! it does for the framed verbs; `NO_COLOR` and `TERM=dumb` are the
//! reader's own statements about the terminal and win over it.

use std::sync::OnceLock;

use super::symbols::{self, Glyphs};
use super::tokens::Palette;

/// Wider than this and a line is harder to read, not easier.
const MAX_WIDTH: usize = 100;
/// Narrower than this and a wrapped row is mostly indent.
const MIN_WIDTH: usize = 20;

/// How a human rendering looks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Look {
    Rich { palette: Palette, width: usize },
    Plain,
}

/// Everything a component needs to know about where it is drawn.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Style {
    pub look: Look,
    pub glyphs: Glyphs,
}

/// Where a verb with a `--json` flag sends its answer.
pub enum Channel {
    Human(Style),
    Json,
}

/// The rendering for a verb that takes `--json`.
pub fn channel(json: bool) -> Channel {
    match json {
        true => Channel::Json,
        false => Channel::Human(style()),
    }
}

/// This run's style, read once: a rendering that changed mid-run would
/// wrap half a report to one width and half to another.
pub fn style() -> Style {
    static STYLE: OnceLock<Style> = OnceLock::new();
    *STYLE.get_or_init(|| {
        let var = |name: &str| std::env::var(name).ok();
        resolve(&Probe {
            capable: super::capable(),
            escapes: escapes_reach_the_terminal(),
            no_color: var("NO_COLOR").is_some_and(|value| !value.is_empty()),
            dumb: var("TERM").as_deref() == Some("dumb"),
            truecolor: matches!(var("COLORTERM").as_deref(), Some("truecolor" | "24bit")),
            glyphs: symbols::for_locale(
                var("LC_ALL").as_deref(),
                var("LC_CTYPE").as_deref(),
                var("LANG").as_deref(),
            ),
            columns: columns(var("COLUMNS").as_deref()),
        })
    })
}

/// Whether each stream a person reads acts on escape sequences. The
/// Windows console host prints them as text until virtual terminal
/// processing is turned on for its handle; `console`'s colour probe turns
/// it on as it answers, and answers no where the console refuses. A stream
/// that is no console at all has nothing to turn on: what reaches it is
/// read as bytes. Everywhere else a terminal acts on them as they are.
#[cfg(windows)]
fn escapes_reach_the_terminal() -> bool {
    [console::Term::stdout(), console::Term::stderr()]
        .iter()
        .all(|term| !term.is_term() || term.features().colors_supported())
}

#[cfg(not(windows))]
fn escapes_reach_the_terminal() -> bool {
    true
}

/// The terminal's width: `COLUMNS` where the shell exported it, which is
/// also how a recording or a test pins one, else what stderr's terminal
/// reports.
fn columns(exported: Option<&str>) -> Option<usize> {
    exported
        .and_then(|value| value.trim().parse().ok())
        .or_else(|| {
            console::Term::stderr()
                .size_checked()
                .map(|(_, cols)| usize::from(cols))
        })
}

/// What the environment said, gathered so the decision is one pure
/// function a table can drive.
struct Probe {
    /// A terminal on both streams, or `KENDEX_UI=pretty`.
    capable: bool,
    /// Every terminal among the streams acts on escape sequences.
    escapes: bool,
    no_color: bool,
    dumb: bool,
    truecolor: bool,
    glyphs: Glyphs,
    columns: Option<usize>,
}

fn resolve(probe: &Probe) -> Style {
    let look = match probe.capable && probe.escapes && !probe.no_color && !probe.dumb {
        false => Look::Plain,
        true => Look::Rich {
            palette: match probe.truecolor {
                true => Palette::Truecolor,
                false => Palette::Ansi16,
            },
            width: probe
                .columns
                .unwrap_or(MAX_WIDTH)
                .clamp(MIN_WIDTH, MAX_WIDTH),
        },
    };
    Style {
        look,
        glyphs: probe.glyphs,
    }
}

/// A piece of text a component draws. Prose breaks between words where a
/// line runs out of room; a command never breaks, since split at a space it
/// reads as a shorter command. [`wrap`] is the one place that rule is kept.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Span<'a> {
    Prose(&'a str),
    Command(&'a str),
}

impl<'a> From<kendex_core::drift::report::Span<'a>> for Span<'a> {
    fn from(span: kendex_core::drift::report::Span<'a>) -> Span<'a> {
        use kendex_core::drift::report::Span as Report;
        match span {
            Report::Prose(text) => Span::Prose(text),
            Report::Command(text) => Span::Command(text),
        }
    }
}

/// `spans` broken into lines no wider than their room in terminal cells:
/// the first line has `first` cells to fill, the rest `rest`, the room each
/// has after its indent. Prose breaks at spaces, and a word wider than the
/// room where it reaches the edge. A command starts a new line where it
/// does not fit on the current one and is never broken: one wider than a
/// whole line is that line, and the terminal wraps it.
pub(super) fn wrap(spans: &[Span<'_>], first: usize, rest: usize) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut room = first.max(1);
    // Whether a space separates the next piece from the one before it:
    // the spans are one text, so a space at a span's edge is still a space.
    let mut spaced = false;
    for span in spans {
        let (text, whole) = match span {
            Span::Prose(text) => (*text, false),
            Span::Command(text) => (*text, true),
        };
        let pieces: Vec<&str> = match whole {
            true => vec![text],
            false => text.split(' ').collect(),
        };
        for (at, piece) in pieces.into_iter().enumerate() {
            spaced |= at > 0;
            if piece.is_empty() {
                continue;
            }
            let used = cells(&line);
            let gap = usize::from(used > 0 && spaced);
            if used > 0 && used + gap + cells(piece) > room {
                lines.push(std::mem::take(&mut line));
                room = rest.max(1);
            } else if gap == 1 {
                line.push(' ');
            }
            spaced = false;
            if whole {
                line.push_str(piece);
                continue;
            }
            for c in piece.chars() {
                let used = cells(&line);
                if used > 0 && used + cells(c.encode_utf8(&mut [0; 4])) > room {
                    lines.push(std::mem::take(&mut line));
                    room = rest.max(1);
                }
                line.push(c);
            }
        }
        spaced |= !whole && text.ends_with(' ');
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// Terminal cells, escape sequences not counted.
pub(super) fn cells(text: &str) -> usize {
    console::measure_text_width(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe() -> Probe {
        Probe {
            capable: true,
            escapes: true,
            no_color: false,
            dumb: false,
            truecolor: false,
            glyphs: Glyphs::Unicode,
            columns: Some(80),
        }
    }

    /// Every way a run ends up plain, and what a rich one is drawn at.
    #[test]
    fn the_environment_picks_the_look() {
        let rich = |palette, width| Look::Rich { palette, width };
        let rows: [(&str, Probe, Look); 9] = [
            ("a terminal", probe(), rich(Palette::Ansi16, 80)),
            (
                "a console that refuses escape sequences",
                Probe {
                    escapes: false,
                    ..probe()
                },
                Look::Plain,
            ),
            (
                "a pipe",
                Probe {
                    capable: false,
                    ..probe()
                },
                Look::Plain,
            ),
            (
                "NO_COLOR",
                Probe {
                    no_color: true,
                    ..probe()
                },
                Look::Plain,
            ),
            (
                "TERM=dumb",
                Probe {
                    dumb: true,
                    ..probe()
                },
                Look::Plain,
            ),
            (
                "truecolor",
                Probe {
                    truecolor: true,
                    ..probe()
                },
                rich(Palette::Truecolor, 80),
            ),
            (
                "wide",
                Probe {
                    columns: Some(240),
                    ..probe()
                },
                rich(Palette::Ansi16, 100),
            ),
            (
                "unknown width",
                Probe {
                    columns: None,
                    ..probe()
                },
                rich(Palette::Ansi16, 100),
            ),
            (
                "narrow",
                Probe {
                    columns: Some(4),
                    ..probe()
                },
                rich(Palette::Ansi16, 20),
            ),
        ];
        for (case, probe, want) in rows {
            assert_eq!(resolve(&probe).look, want, "{case}");
        }
        let ascii = Probe {
            glyphs: Glyphs::Ascii,
            capable: false,
            ..probe()
        };
        assert_eq!(
            resolve(&ascii).glyphs,
            Glyphs::Ascii,
            "plain keeps the locale's glyphs"
        );
    }

    /// Words stay whole where they fit, and no line passes its room.
    #[test]
    fn wrapping_breaks_at_spaces_within_the_room() {
        let prose = |text| wrap(&[Span::Prose(text)], 7, 7);
        assert_eq!(prose("one two three"), ["one two", "three"]);
        assert_eq!(
            wrap(&[Span::Prose("one two three")], 3, 9),
            ["one", "two three"]
        );
        assert_eq!(wrap(&[Span::Prose("abcdefgh")], 3, 3), ["abc", "def", "gh"]);
        assert_eq!(prose(""), Vec::<String>::new());
        for line in wrap(&[Span::Prose("a b cc ddd eeee fffff gggggg ✓✓✓✓✓")], 5, 4)
            .iter()
            .skip(1)
        {
            assert!(cells(line) <= 4, "{line:?}");
        }
    }

    /// A command moves whole to the next line rather than split, and one
    /// wider than any line is a line of its own; the prose around it keeps
    /// its spaces, and a span edge with no space stays joined.
    #[test]
    fn a_command_is_never_broken() {
        let next = [
            Span::Prose("Next: "),
            Span::Command("kendex refresh --scope project --yes"),
            Span::Prose(" in this checkout."),
        ];
        assert_eq!(
            wrap(&next, 40, 40),
            [
                "Next:",
                "kendex refresh --scope project --yes in",
                "this checkout."
            ]
        );
        assert_eq!(
            wrap(&next, 20, 20),
            [
                "Next:",
                "kendex refresh --scope project --yes",
                "in this checkout."
            ]
        );
        assert_eq!(
            wrap(
                &[
                    Span::Prose("("),
                    Span::Command("kendex check"),
                    Span::Prose(")")
                ],
                40,
                40
            ),
            ["(kendex check)"]
        );
    }
}
