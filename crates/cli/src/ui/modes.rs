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

/// `text` broken at spaces into lines no wider than `width` terminal
/// cells, a word wider than that broken where it reaches the edge. The
/// first line has `first` cells to fill, the rest `rest`: the room each
/// has after its indent.
pub(super) fn wrap(text: &str, first: usize, rest: usize) -> Vec<String> {
    let mut lines: Vec<String> = Vec::new();
    let mut line = String::new();
    let mut room = first.max(1);
    for word in text.split(' ').filter(|word| !word.is_empty()) {
        let used = cells(&line);
        if used > 0 && used + 1 + cells(word) > room {
            lines.push(std::mem::take(&mut line));
            room = rest.max(1);
        } else if used > 0 {
            line.push(' ');
        }
        for c in word.chars() {
            let used = cells(&line);
            if used > 0 && used + cells(c.encode_utf8(&mut [0; 4])) > room {
                lines.push(std::mem::take(&mut line));
                room = rest.max(1);
            }
            line.push(c);
        }
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
        assert_eq!(wrap("one two three", 7, 7), ["one two", "three"]);
        assert_eq!(wrap("one two three", 3, 9), ["one", "two three"]);
        assert_eq!(wrap("abcdefgh", 3, 3), ["abc", "def", "gh"]);
        assert_eq!(wrap("", 10, 10), Vec::<String>::new());
        for line in wrap("a b cc ddd eeee fffff gggggg ✓✓✓✓✓", 5, 4)
            .iter()
            .skip(1)
        {
            assert!(cells(line) <= 4, "{line:?}");
        }
    }
}
