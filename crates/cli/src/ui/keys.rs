//! The single-key read: a question drawn as [`Style::choices`] and answered
//! by pressing one of the keys it shows.
//!
//! Enter takes the choice drawn as the default, and every question has
//! exactly one. Escape and Ctrl-C cancel: the read comes back as an
//! interrupted error, which [`super::cancelled`] recognises and the run
//! exits 130 on, having written nothing the question asked about. A key
//! the question does not show is ignored and the read waits for another,
//! so a stray key picks nothing.
//!
//! Only a run with a terminal on stdin is asked: a run with nobody to ask
//! refuses before its first write, naming the flag that answers instead,
//! and never reaches a read. Keys are read raw where the question is drawn
//! on a terminal. Where stderr is redirected, as in `2>&1 | tee log`, the
//! person cannot see a raw prompt redraw, so the answer is a typed line
//! whose first character is the key and whose empty line is Enter.

use std::io::{self, IsTerminal, Write};

use console::Key as Pressed;

use super::components::{Choice, Key};
use super::escaped;
use super::modes::{Style, cells, style};

/// Draw `options` as keyed buttons under what the caller drew above, and
/// read the one the person presses.
pub fn choose<T: Copy>(options: &[(Choice<'_>, T)]) -> io::Result<T> {
    let mut keys = Keys::for_this_run()?;
    asked(&style(), options, || keys.next(), super::stderr)
}

/// Read a line the person types, for a question whose answer is text rather
/// than one of a few choices. Escape and Ctrl-C cancel as [`choose`] does;
/// the line comes back trimmed, empty where nothing was typed.
pub fn typed() -> io::Result<String> {
    let style = style();
    let prompt = style.picked("").concat();
    match Keys::for_this_run()? {
        Keys::Raw(term) => {
            super::flush();
            term.write_str(&prompt)?;
            let mut text = Typed::default();
            loop {
                match term.read_key_raw() {
                    Ok(Pressed::Enter) => break,
                    Ok(Pressed::Char(c)) if !c.is_control() => term.write_str(&text.push(c))?,
                    Ok(Pressed::Backspace) => {
                        if let Some(wide) = text.pop() {
                            term.clear_chars(wide)?;
                        }
                    }
                    Ok(Pressed::Escape | Pressed::CtrlC) => return Err(cancel(&term)),
                    Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => {
                        return Err(cancel(&term));
                    }
                    Err(error) => return Err(error),
                    Ok(_) => {}
                }
            }
            term.write_line("")?;
            Ok(text.text.trim().to_owned())
        }
        Keys::Typed => {
            super::flush();
            let mut err = io::stderr().lock();
            let _ = write!(err, "{prompt}");
            let _ = err.flush();
            drop(err);
            match typed_line()? {
                Some(line) => Ok(line.trim().to_owned()),
                None => Err(io::Error::from(io::ErrorKind::Interrupted)),
            }
        }
    }
}

/// The line under a raw read ends where the cancel left it, so the lines
/// the run prints next start at column 0.
fn cancel(term: &console::Term) -> io::Error {
    let _ = term.write_line("");
    io::Error::from(io::ErrorKind::Interrupted)
}

/// What a raw line read holds, and the cells each character was echoed in,
/// so a backspace clears what the terminal shows rather than one cell.
#[derive(Default)]
struct Typed {
    text: String,
    echoed: Vec<usize>,
}

impl Typed {
    /// Take one character, and hand back its echo: escaped, so an
    /// invisible or direction-flipping character typed or pasted in shows
    /// as its escape rather than acting on the line.
    fn push(&mut self, c: char) -> String {
        self.text.push(c);
        let echo = escaped(&c.to_string());
        self.echoed.push(cells(&echo));
        echo
    }

    fn pop(&mut self) -> Option<usize> {
        self.text.pop()?;
        self.echoed.pop()
    }
}

/// Where this run's keys come from.
enum Keys {
    /// One key at a time, unechoed, off the terminal the question is on.
    Raw(console::Term),
    /// A typed line per answer, off stdin, for a question drawn on a
    /// redirected stderr.
    Typed,
}

impl Keys {
    /// Refuses where stdin is no terminal: every caller refuses a run with
    /// nobody to ask before its first write, so a read reached without one
    /// is a caller that skipped that refusal, and waiting on a pipe is the
    /// one thing a question must never do.
    fn for_this_run() -> io::Result<Keys> {
        if !io::stdin().is_terminal() {
            return Err(io::Error::other(
                "no terminal to ask at: a question was reached by a run with nobody to answer it",
            ));
        }
        let term = console::Term::stderr();
        Ok(match term.is_term() {
            true => Keys::Raw(term),
            false => Keys::Typed,
        })
    }

    fn next(&mut self) -> io::Result<Pressed> {
        match self {
            Keys::Raw(term) => term.read_key_raw(),
            Keys::Typed => match typed_line()? {
                None => Err(io::Error::from(io::ErrorKind::UnexpectedEof)),
                Some(line) => Ok(match line.trim().chars().next() {
                    None => Pressed::Enter,
                    Some(c) => Pressed::Char(c),
                }),
            },
        }
    }
}

/// One line off stdin, or `None` at the end of input.
fn typed_line() -> io::Result<Option<String>> {
    let mut line = String::new();
    match io::stdin().read_line(&mut line)? {
        0 => Ok(None),
        _ => Ok(Some(line)),
    }
}

/// What one key does to a question.
#[derive(Debug, PartialEq, Eq)]
enum Answer {
    /// The choice at this index.
    Picked(usize),
    Cancel,
    /// A key the question does not show.
    Ignored,
}

/// The question: draw its buttons, read keys until one picks or cancels,
/// and draw the choice picked. `read` hands back each key and `draw` prints
/// what was drawn, so a test drives the same question with its own keys.
pub(super) fn asked<T: Copy>(
    style: &Style,
    options: &[(Choice<'_>, T)],
    mut read: impl FnMut() -> io::Result<Pressed>,
    mut draw: impl FnMut(&[String]),
) -> io::Result<T> {
    let shown: Vec<Choice<'_>> = options.iter().map(|(choice, _)| *choice).collect();
    one_default_and_distinct_keys(&shown)?;
    draw(&style.choices(&shown));
    loop {
        match answer(&shown, read()) {
            Answer::Picked(at) => {
                draw(&style.picked(shown[at].label));
                return Ok(options[at].1);
            }
            Answer::Cancel => return Err(io::Error::from(io::ErrorKind::Interrupted)),
            Answer::Ignored => {}
        }
    }
}

/// The key read against the choices shown. Letters match either case, so
/// Caps Lock does not turn every key into one the question ignores. The
/// end of input cancels: no key can follow it, and taking the default
/// there would answer a question nobody saw through to the end.
fn answer(shown: &[Choice<'_>], pressed: io::Result<Pressed>) -> Answer {
    let wanted = match pressed {
        Ok(Pressed::Escape | Pressed::CtrlC) => return Answer::Cancel,
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Answer::Cancel,
        Ok(Pressed::Enter) => Key::Enter,
        Ok(Pressed::Char(c)) => Key::Char(c),
        Ok(_) | Err(_) => return Answer::Ignored,
    };
    shown
        .iter()
        .position(|choice| same(choice.key, wanted))
        .map_or(Answer::Ignored, Answer::Picked)
}

fn same(key: Key, pressed: Key) -> bool {
    match (key, pressed) {
        (Key::Enter, Key::Enter) => true,
        (Key::Char(key), Key::Char(pressed)) => key.to_lowercase().eq(pressed.to_lowercase()),
        (Key::Enter, Key::Char(_)) | (Key::Char(_), Key::Enter) => false,
    }
}

/// A question every key of which picks one choice, with one default for
/// Enter to take. The lists are the callers' own constants, so a failure
/// here is a list written wrong, said before anything is drawn.
fn one_default_and_distinct_keys(shown: &[Choice<'_>]) -> io::Result<()> {
    let defaults = shown
        .iter()
        .filter(|choice| choice.key == Key::Enter)
        .count();
    let clash = shown.iter().enumerate().any(|(at, choice)| {
        shown[at + 1..]
            .iter()
            .any(|other| same(choice.key, other.key))
    });
    match (defaults, clash) {
        (1, false) => Ok(()),
        _ => Err(io::Error::other(format!(
            "choices-invalid: {} default(s), keys {}: a question takes one Enter default and distinct keys",
            defaults,
            match clash {
                true => "repeat",
                false => "distinct",
            }
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CHOICES: [(Choice<'static>, char); 3] = [
        (
            Choice {
                key: Key::Char('c'),
                label: "commit them",
            },
            'c',
        ),
        (
            Choice {
                key: Key::Char('?'),
                label: "show everything",
            },
            '?',
        ),
        (
            Choice {
                key: Key::Enter,
                label: "leave them as diffs",
            },
            'l',
        ),
    ];

    fn shown() -> Vec<Choice<'static>> {
        CHOICES.iter().map(|(choice, _)| *choice).collect()
    }

    fn eof() -> io::Result<Pressed> {
        Err(io::Error::from(io::ErrorKind::UnexpectedEof))
    }

    /// Each key against the choices shown: a shown key picks its choice in
    /// either case, Enter takes the default, Escape, Ctrl-C and the end of
    /// input cancel, and anything else is ignored.
    #[test]
    fn a_key_picks_the_choice_it_shows() {
        let rows: [(&str, io::Result<Pressed>, Answer); 11] = [
            ("its key", Ok(Pressed::Char('c')), Answer::Picked(0)),
            (
                "its key in capitals",
                Ok(Pressed::Char('C')),
                Answer::Picked(0),
            ),
            ("a symbol key", Ok(Pressed::Char('?')), Answer::Picked(1)),
            ("Enter", Ok(Pressed::Enter), Answer::Picked(2)),
            ("Escape", Ok(Pressed::Escape), Answer::Cancel),
            ("Ctrl-C", Ok(Pressed::CtrlC), Answer::Cancel),
            ("the end of input", eof(), Answer::Cancel),
            ("a key not shown", Ok(Pressed::Char('x')), Answer::Ignored),
            ("a digit", Ok(Pressed::Char('1')), Answer::Ignored),
            ("an arrow", Ok(Pressed::ArrowDown), Answer::Ignored),
            (
                "a read that failed otherwise",
                Err(io::Error::from(io::ErrorKind::WouldBlock)),
                Answer::Ignored,
            ),
        ];
        for (what, pressed, want) in rows {
            assert_eq!(answer(&shown(), pressed), want, "{what}");
        }
    }

    /// A question with no default, two, or two choices on one key is
    /// refused before it is drawn: Enter would pick nothing or pick at
    /// random, and a repeated key would hide the second choice.
    #[test]
    fn a_question_takes_one_default_and_distinct_keys() {
        let choice = |key| Choice { key, label: "x" };
        let rows: [(&str, Vec<Choice<'_>>, bool); 5] = [
            ("shown", shown(), true),
            ("no default", vec![choice(Key::Char('a'))], false),
            (
                "two defaults",
                vec![choice(Key::Enter), choice(Key::Enter)],
                false,
            ),
            (
                "one key twice",
                vec![
                    choice(Key::Char('a')),
                    choice(Key::Enter),
                    choice(Key::Char('A')),
                ],
                false,
            ),
            (
                "distinct",
                vec![
                    choice(Key::Char('a')),
                    choice(Key::Char('b')),
                    choice(Key::Enter),
                ],
                true,
            ),
        ];
        for (what, choices, valid) in rows {
            assert_eq!(
                one_default_and_distinct_keys(&choices).is_ok(),
                valid,
                "{what}"
            );
        }
        let refused = asked(
            &crate::ui::testing::plain(),
            &[(choice(Key::Char('a')), ())],
            || panic!("a refused question read a key"),
            |lines| panic!("a refused question drew {lines:?}"),
        );
        assert!(refused.is_err());
    }

    /// Ignored keys draw nothing and read on; the answer is the first key
    /// that picks, and the choice it picked is drawn under the buttons.
    #[test]
    fn an_ignored_key_reads_on_to_the_one_that_picks() {
        let mut keys = vec![
            Ok(Pressed::Char('x')),
            Ok(Pressed::Char('1')),
            Ok(Pressed::Char('c')),
        ]
        .into_iter();
        let mut drawn = Vec::new();
        let picked = asked(
            &crate::ui::testing::plain(),
            &CHOICES,
            || keys.next().unwrap_or_else(eof),
            |lines| drawn.extend_from_slice(lines),
        );
        assert_eq!(picked.ok(), Some('c'));
        assert_eq!(
            drawn,
            [
                "  [c] commit them · [?] show everything · [Enter] leave them as diffs",
                "  › commit them",
            ]
        );
        assert!(keys.next().is_none(), "read past the key that picked");
    }

    /// A cancel is the interrupted error the run exits 130 on, and draws no
    /// choice as picked.
    #[test]
    fn escape_cancels_with_nothing_picked() {
        let mut drawn = Vec::new();
        let cancelled = asked(
            &crate::ui::testing::plain(),
            &CHOICES,
            || Ok(Pressed::Escape),
            |lines| drawn.extend_from_slice(lines),
        );
        let error = cancelled.expect_err("Escape picked a choice");
        assert!(crate::ui::cancelled(&error), "{error:?}");
        assert_eq!(drawn.len(), 1, "{drawn:?}");
    }

    /// A backspace clears the cells its character was echoed in, an
    /// escaped one included.
    #[test]
    fn a_backspace_clears_what_its_character_echoed() {
        let mut typed = Typed::default();
        assert_eq!(typed.push('a'), "a");
        let echo = typed.push('\u{202e}');
        assert_ne!(echo, "\u{202e}", "a bidi override was echoed as itself");
        assert_eq!(typed.pop(), Some(cells(&echo)));
        assert_eq!(typed.pop(), Some(1));
        assert_eq!(typed.pop(), None);
        assert_eq!(typed.text, "");
    }
}
