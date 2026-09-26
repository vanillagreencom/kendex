//! The components every converted verb is built from. Each one takes raw
//! values, escapes them, and hands back the lines it draws in the run's
//! [`Style`]; [`super::stdout`] and [`super::stderr`] print them. No verb
//! composes a line of its own, so a verb cannot draw differently from the
//! next one, and cannot forget the escape.
//!
//! The plain rendering of each component is the grammar scripts read: a
//! line at column 0 opens a block, two spaces make a line detail of it, and
//! chrome — the header, a spinner, a progress bar, the blank lines between
//! sections — is not drawn at all. The rich rendering adds colour, glyphs,
//! spacing and wrapping to the same lines.
//!
//! `crates/cli/OUTPUT.md` is the reference a verb author follows.

use std::path::Path;

use super::escaped;
use super::modes::{Look, Style, cells, wrap};
use super::symbols::{Glyphs, Symbol};
use super::tokens::{Token, paint, strong};

/// What a line says about its subject.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Status {
    Done,
    /// Failed, or blocked.
    Failed,
    /// Needs a decision from the reader.
    Decision,
    Notice,
}

impl Status {
    fn symbol(self) -> Symbol {
        match self {
            Status::Done => Symbol::Done,
            Status::Failed => Symbol::Failed,
            Status::Decision => Symbol::Decision,
            Status::Notice => Symbol::Notice,
        }
    }

    fn token(self) -> Token {
        match self {
            Status::Done => Token::Ok,
            Status::Failed => Token::Danger,
            Status::Decision => Token::Warn,
            Status::Notice => Token::Info,
        }
    }
}

/// One keyed choice of a [`Style::choices`] line.
pub struct Choice<'a> {
    /// What to press: `Enter`, `s`, `?`.
    pub key: &'a str,
    pub label: &'a str,
    /// The one drawn as the default.
    pub recommended: bool,
}

/// What a [`Style::link`] opens.
pub enum Target<'a> {
    File(&'a Path),
    Url(&'a str),
}

/// Spinner frames, one per tick.
const SPIN_UNICODE: [&str; 10] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const SPIN_ASCII: [&str; 4] = ["|", "/", "-", "\\"];
/// Cells a progress bar spans.
const BAR: usize = 20;

impl Style {
    fn glyph(&self, symbol: Symbol) -> &'static str {
        symbol.glyph(self.glyphs)
    }

    /// The verb and what it acts on, one line. Chrome: plain draws nothing,
    /// since whoever reads a pipe already knows what they ran.
    pub fn header(&self, verb: &str, target: &str) -> Vec<String> {
        let Look::Rich { palette, width } = self.look else {
            return Vec::new();
        };
        let title = format!("kendex {}", escaped(verb));
        let lead = format!("{}  ", strong(palette, Token::Accent, &title));
        fitted(
            width,
            &lead,
            cells(&title) + 2,
            2,
            &escaped(target),
            |chunk| paint(palette, Token::Muted, chunk),
        )
    }

    /// A titled group and how many rows it holds, set off by a blank line.
    pub fn section(&self, title: &str, count: usize, status: Status) -> Vec<String> {
        let title = escaped(title);
        match self.look {
            Look::Plain => vec![format!("{title}:")],
            Look::Rich { palette, .. } => vec![
                String::new(),
                format!(
                    "{}  {}",
                    strong(palette, status.token(), &title),
                    paint(palette, Token::Muted, &count.to_string())
                ),
            ],
        }
    }

    /// One thing, what is true of it, and what goes with it: a remedy, a
    /// version, a path.
    pub fn row(&self, status: Status, label: &str, value: Option<&str>) -> Vec<String> {
        let (label, value) = (escaped(label), value.map(escaped));
        match self.look {
            Look::Plain => vec![match value {
                Some(value) => format!("  {label} — {value}"),
                None => format!("  {label}"),
            }],
            Look::Rich { palette, width } => {
                let lead = format!(
                    "  {} ",
                    paint(palette, status.token(), self.glyph(status.symbol()))
                );
                let mut lines = fitted(width, &lead, 4, 4, &label, str::to_owned);
                if let Some(value) = value {
                    lines.extend(fitted(width, "    ", 4, 4, &value, |chunk| {
                        paint(palette, Token::Info, chunk)
                    }));
                }
                lines
            }
        }
    }

    /// A named value moving from one version to another, with the scope it
    /// moved in.
    pub fn change(&self, name: &str, old: &str, new: &str, scope: Option<&str>) -> Vec<String> {
        let arrow = self.glyph(Symbol::Change);
        let (name, old, new) = (escaped(name), escaped(old), escaped(new));
        let scope = scope.map(|scope| format!("[{}]", escaped(scope)));
        match self.look {
            Look::Plain => vec![
                format!(
                    "  {name}  {old} {arrow} {new}  {}",
                    scope.unwrap_or_default()
                )
                .trim_end()
                .to_owned(),
            ],
            Look::Rich { palette, .. } => vec![
                format!(
                    "  {}  {} {} {}  {}",
                    strong(palette, Token::Emphasis, &name),
                    paint(palette, Token::Muted, &old),
                    paint(palette, Token::Accent, arrow),
                    new,
                    paint(palette, Token::Muted, &scope.unwrap_or_default()),
                )
                .trim_end()
                .to_owned(),
            ],
        }
    }

    /// Something that needs the reader: what it is, why, and what they can
    /// press about it.
    pub fn callout(&self, what: &str, why: &str, choices: &[Choice<'_>]) -> Vec<String> {
        let mark = self.glyph(Symbol::Decision);
        let (what, why) = (escaped(what), escaped(why));
        let mut lines = match self.look {
            Look::Plain => vec![format!("{mark} {what}"), format!("  {why}")],
            Look::Rich { palette, width } => {
                let lead = format!("{} ", paint(palette, Token::Warn, mark));
                let mut lines = vec![String::new()];
                lines.extend(fitted(width, &lead, 2, 2, &what, |chunk| {
                    strong(palette, Token::Emphasis, chunk)
                }));
                lines.extend(fitted(width, "  ", 2, 2, &why, str::to_owned));
                lines
            }
        };
        lines.extend(
            self.choices(choices)
                .into_iter()
                .map(|line| format!("  {line}")),
        );
        lines
    }

    /// Keyed buttons on one line, the recommended one drawn as the default:
    /// `[Enter] Set up · [s] Skip · [?] Details`.
    pub fn choices(&self, choices: &[Choice<'_>]) -> Vec<String> {
        if choices.is_empty() {
            return Vec::new();
        }
        let divider = format!(" {} ", self.glyph(Symbol::Divider));
        let each = choices.iter().map(|choice| {
            let (key, label) = (format!("[{}]", escaped(choice.key)), escaped(choice.label));
            match (self.look, choice.recommended) {
                (Look::Plain, _) => format!("{key} {label}"),
                (Look::Rich { palette, .. }, true) => format!(
                    "{} {}",
                    strong(palette, Token::Accent, &key),
                    strong(palette, Token::Emphasis, &label)
                ),
                (Look::Rich { palette, .. }, false) => format!(
                    "{} {}",
                    paint(palette, Token::Accent, &key),
                    paint(palette, Token::Muted, &label)
                ),
            }
        });
        let divider = match self.look {
            Look::Plain => divider,
            Look::Rich { palette, .. } => paint(palette, Token::Muted, &divider),
        };
        vec![each.collect::<Vec<_>>().join(&divider)]
    }

    /// A file or a URL the reader can open. Rich wraps it in an OSC 8
    /// hyperlink, which a terminal that does not know the sequence skips,
    /// so the text still reads there; plain is the text alone.
    pub fn link(&self, text: &str, target: Target<'_>) -> Vec<String> {
        let text = escaped(text);
        let Look::Rich { palette, .. } = self.look else {
            return vec![format!("  {text}")];
        };
        let url = match target {
            Target::Url(url) => escaped(url),
            Target::File(path) => file_url(path),
        };
        vec![format!(
            "  \x1b]8;;{url}\x1b\\{}\x1b]8;;\x1b\\",
            paint(palette, Token::Info, &text)
        )]
    }

    /// Columns sized to their widest cell, a rule under the header.
    pub fn table(&self, headers: &[&str], rows: &[Vec<String>]) -> Vec<String> {
        let headers: Vec<String> = headers.iter().map(|cell| escaped(cell)).collect();
        let rows: Vec<Vec<String>> = rows
            .iter()
            .map(|row| row.iter().map(|cell| escaped(cell)).collect())
            .collect();
        let widths: Vec<usize> = (0..headers.len())
            .map(|column| {
                std::iter::once(&headers)
                    .chain(&rows)
                    .filter_map(|row| row.get(column))
                    .map(|cell| cells(cell))
                    .max()
                    .unwrap_or(0)
            })
            .collect();
        let laid = |row: &[String], paint_cell: &dyn Fn(&str) -> String| {
            row.iter()
                .zip(&widths)
                .map(|(cell, room)| {
                    let pad = " ".repeat(room.saturating_sub(cells(cell)));
                    format!("{}{pad}", paint_cell(cell))
                })
                .collect::<Vec<_>>()
                .join("  ")
                .trim_end()
                .to_owned()
        };
        match self.look {
            Look::Plain => std::iter::once(laid(&headers, &str::to_owned))
                .chain(rows.iter().map(|row| laid(row, &str::to_owned)))
                .collect(),
            Look::Rich { palette, .. } => {
                let rule_cells = widths.iter().sum::<usize>() + 2 * widths.len().saturating_sub(1);
                let rule = self.glyph(Symbol::Separator).repeat(rule_cells);
                let header = laid(&headers, &|cell| strong(palette, Token::Muted, cell));
                [
                    format!("  {header}"),
                    format!("  {}", paint(palette, Token::Muted, &rule)),
                ]
                .into_iter()
                .chain(
                    rows.iter()
                        .map(|row| format!("  {}", laid(row, &str::to_owned))),
                )
                .collect()
            }
        }
    }

    /// One frame of work in progress. Chrome: plain draws nothing, which is
    /// what keeps a pipe's lines the outcomes and not the waiting.
    pub fn spinner(&self, label: &str, tick: usize) -> Vec<String> {
        let Look::Rich { palette, .. } = self.look else {
            return Vec::new();
        };
        let frame = match self.glyphs {
            Glyphs::Unicode => SPIN_UNICODE[tick % SPIN_UNICODE.len()],
            Glyphs::Ascii => SPIN_ASCII[tick % SPIN_ASCII.len()],
        };
        vec![format!(
            "{} {}",
            paint(palette, Token::Accent, frame),
            escaped(label)
        )]
    }

    /// How far a counted run has got. Chrome, like [`Style::spinner`].
    pub fn progress(&self, done: usize, total: usize, label: &str) -> Vec<String> {
        let Look::Rich { palette, .. } = self.look else {
            return Vec::new();
        };
        let filled = match total {
            0 => BAR,
            _ => BAR * done.min(total) / total,
        };
        let (full, empty) = match self.glyphs {
            Glyphs::Unicode => ("━", "─"),
            Glyphs::Ascii => ("#", "-"),
        };
        vec![format!(
            "{}{} {} {}",
            paint(palette, Token::Accent, &full.repeat(filled)),
            paint(palette, Token::Muted, &empty.repeat(BAR - filled)),
            paint(palette, Token::Muted, &format!("{done}/{total}")),
            escaped(label)
        )]
    }

    /// How the run ended, its last line.
    pub fn summary(&self, status: Status, text: &str) -> Vec<String> {
        let text = escaped(text);
        let Look::Rich { palette, width } = self.look else {
            return vec![text];
        };
        let lead = format!(
            "{} ",
            paint(palette, status.token(), self.glyph(status.symbol()))
        );
        let mut lines = vec![String::new()];
        lines.extend(fitted(width, &lead, 2, 2, &text, |chunk| {
            strong(palette, Token::Emphasis, chunk)
        }));
        lines
    }

    /// Raw output under a title. Folded, rich shows the title and how much
    /// is under it; plain has nobody to unfold it and prints every line.
    pub fn details(&self, title: &str, lines: &[&str], folded: bool) -> Vec<String> {
        let title = escaped(title);
        let body = lines.iter().map(|line| escaped(line));
        let Look::Rich { palette, .. } = self.look else {
            return std::iter::once(format!("  {title}"))
                .chain(body.map(|line| format!("    {line}")))
                .collect();
        };
        let mark = paint(palette, Token::Muted, self.glyph(Symbol::Current));
        match folded {
            true => vec![format!(
                "  {mark} {title} {}",
                paint(palette, Token::Muted, &format!("({} lines)", lines.len()))
            )],
            false => std::iter::once(format!("  {mark} {title}"))
                .chain(body.map(|line| format!("    {}", paint(palette, Token::Muted, &line))))
                .collect(),
        }
    }

    /// A footnote to what is above it: an age, a pointer onward.
    pub fn note(&self, text: &str) -> Vec<String> {
        let text = escaped(text);
        match self.look {
            Look::Plain => vec![text],
            Look::Rich { palette, width } => fitted(width, "", 0, 0, &text, |chunk| {
                paint(palette, Token::Muted, chunk)
            }),
        }
    }
}

/// `text` as rich lines no wider than `width`, behind `lead` (already
/// painted, `lead_cells` wide), continuation lines indented by `indent`
/// cells, each chunk painted by `paint_chunk`.
fn fitted(
    width: usize,
    lead: &str,
    lead_cells: usize,
    indent: usize,
    text: &str,
    paint_chunk: impl Fn(&str) -> String,
) -> Vec<String> {
    let room = |used: usize| width.saturating_sub(used);
    wrap(text, room(lead_cells), room(indent))
        .iter()
        .enumerate()
        .map(|(at, chunk)| match at {
            0 => format!("{lead}{}", paint_chunk(chunk)),
            _ => format!("{}{}", " ".repeat(indent), paint_chunk(chunk)),
        })
        .collect()
}

/// A `file://` URL for a path, every byte a URL cannot carry
/// percent-encoded, so an escape or a space in a name cannot end it.
fn file_url(path: &Path) -> String {
    let slashed = kendex_core::paths::slashed(path);
    let rooted = match slashed.starts_with('/') {
        true => slashed,
        false => format!("/{slashed}"),
    };
    let mut url = String::from("file://");
    for byte in rooted.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'/' | b'-' | b'.' | b'_' | b'~' | b':' => {
                url.push(char::from(byte));
            }
            _ => url.push_str(&format!("%{byte:02X}")),
        }
    }
    url
}

#[cfg(test)]
mod tests;
