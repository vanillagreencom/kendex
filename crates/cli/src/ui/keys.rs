//! The single-key read: a question drawn as [`Style::choices`] and answered
//! by pressing one of the keys it shows.
//!
//! Enter takes the choice drawn as the default, and every question has
//! exactly one. Escape, Ctrl-C and the end of input cancel: the read comes
//! back as an interrupted error, which [`super::cancelled`] recognises and
//! the run exits 130 on, having written nothing the question asked about. A
//! key the question does not show is ignored and the read waits for another,
//! so a stray key picks nothing. Keys that reached the terminal before a
//! question is drawn are discarded. A key typed after it is drawn answers
//! it, an Enter included that follows a key leading straight to an
//! instantly drawn question, such as the offer's `c` and the message
//! question after it.
//!
//! A question needs a terminal on stdin, and [`choose`] refuses to wait on
//! a pipe. Each caller settles a run with nobody to ask before it reaches a
//! question; `crates/cli/OUTPUT.md` § Questions says how each one does.
//!
//! Keys are read raw where the question is drawn on a terminal. Where
//! stderr is redirected, as in `2>&1 | tee log`, the answer is a typed line:
//! its first character is the key, an empty line is Enter, and a line
//! starting with Escape cancels. Ctrl-C there is the terminal's own signal,
//! which ends the run.

use std::io::{self, IsTerminal, Write};

use console::Key as Pressed;

use super::components::{Choice, Key};
use super::escaped;
use super::modes::{Style, cells, style};

/// Draw `options` as keyed buttons under what the caller drew above, and
/// read the one the person presses.
pub fn choose<T: Copy>(options: &[(Choice<'_>, T)]) -> io::Result<T> {
    let mut keys = Keys::ready()?;
    let reading = keys.reading;
    asked(&style(), reading, options, || keys.next(), super::stderr)
}

/// The consent a write needs: the question as a callout, `[y] yes` and
/// `[Enter] no`. Enter, the answer a stray key is likeliest to be, never
/// writes.
pub fn consent(question: &str) -> io::Result<bool> {
    let mut keys = Keys::ready()?;
    let reading = keys.reading;
    consented(&style(), reading, question, || keys.next(), super::stderr)
}

fn consented(
    style: &Style,
    reading: Reading,
    question: &str,
    read: impl FnMut() -> io::Result<Pressed>,
    mut draw: impl FnMut(&[String]),
) -> io::Result<bool> {
    draw(&style.callout(question, None, &[]));
    asked(style, reading, &CONSENT, read, draw)
}

const CONSENT: [(Choice<'static>, bool); 2] = [
    (
        Choice {
            key: Key::Char('y'),
            label: "yes",
        },
        true,
    ),
    (
        Choice {
            key: Key::Enter,
            label: "no",
        },
        false,
    ),
];

/// Read a line the person types, for a question whose answer is text rather
/// than one of a few choices. It cancels on the keys [`choose`] cancels on;
/// the line comes back trimmed, empty where nothing was typed.
///
/// Queued keys are kept: a text question follows the key that led to it,
/// and what was typed after that key is the text.
pub fn typed() -> io::Result<String> {
    let style = style();
    let prompt = style.picked("").concat();
    let keys = Keys::open()?;
    super::flush();
    match keys.reading {
        Reading::Keys => {
            let term = &keys.term;
            term.write_str(&prompt)?;
            let mut text = Typed::default();
            loop {
                let pressed = term.read_key_raw();
                if cancels(&pressed) {
                    let _ = term.write_line("");
                    return Err(io::Error::from(io::ErrorKind::Interrupted));
                }
                match pressed? {
                    Pressed::Enter => break,
                    Pressed::Char(c) if !c.is_control() => term.write_str(&text.push(c))?,
                    Pressed::Backspace => {
                        if let Some(wide) = text.pop() {
                            term.clear_chars(wide)?;
                        }
                    }
                    _ => {}
                }
            }
            term.write_line("")?;
            Ok(text.text.trim().to_owned())
        }
        Reading::Lines => {
            let mut err = io::stderr().lock();
            let _ = write!(err, "{prompt}");
            let _ = err.flush();
            drop(err);
            let line = typed_line()?;
            if cancels(&line_key(line.as_deref())) {
                return Err(io::Error::from(io::ErrorKind::Interrupted));
            }
            Ok(line_text(line.as_deref().unwrap_or_default()))
        }
    }
}

/// Whether a key read ends the question as a cancel. The one set of cancel
/// keys, for a choice and for a line alike. The end of input cancels: no
/// key can follow it, and taking the default there would answer a question
/// nobody saw through to the end.
fn cancels(pressed: &io::Result<Pressed>) -> bool {
    match pressed {
        Ok(Pressed::Escape | Pressed::CtrlC) => true,
        Err(error) => error.kind() == io::ErrorKind::UnexpectedEof,
        Ok(_) => false,
    }
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

/// How this run's answers are read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reading {
    /// One key at a time, unechoed, off the terminal the question is on.
    Keys,
    /// A typed line per answer, off stdin, for a question drawn on a
    /// redirected stderr.
    Lines,
}

/// Where answers come from: stdin must be a terminal, and a question drawn
/// on one is answered by keys. Waiting on a pipe is the one thing a
/// question must never do, so a run without one is refused here whatever
/// its caller settled before.
fn reading(stdin_is_terminal: bool, stderr_is_terminal: bool) -> io::Result<Reading> {
    match (stdin_is_terminal, stderr_is_terminal) {
        (false, _) => Err(io::Error::other(
            "no terminal to ask at: a question was reached by a run with nobody to answer it",
        )),
        (true, true) => Ok(Reading::Keys),
        (true, false) => Ok(Reading::Lines),
    }
}

/// This run's answers, off the terminal a question is drawn on.
struct Keys {
    reading: Reading,
    term: console::Term,
}

impl Keys {
    fn open() -> io::Result<Keys> {
        let term = console::Term::stderr();
        Ok(Keys {
            reading: reading(io::stdin().is_terminal(), term.is_term())?,
            term,
        })
    }

    /// Opened for a new question: what reached the terminal before it is
    /// dropped.
    fn ready() -> io::Result<Keys> {
        let keys = Keys::open()?;
        discard_typed_ahead()?;
        Ok(keys)
    }

    fn next(&mut self) -> io::Result<Pressed> {
        match self.reading {
            Reading::Keys => self.term.read_key_raw(),
            Reading::Lines => line_key(typed_line()?.as_deref()),
        }
    }
}

/// Drop what stdin's terminal holds unread.
#[cfg(unix)]
fn discard_typed_ahead() -> io::Result<()> {
    rustix::termios::tcflush(io::stdin(), rustix::termios::QueueSelector::IFlush)
        .map_err(io::Error::from)
}

/// Drop what the console input buffer holds unread.
#[cfg(windows)]
#[allow(
    unsafe_code,
    reason = "Win32 has no safe binding for the console input flush"
)]
fn discard_typed_ahead() -> io::Result<()> {
    use windows_sys::Win32::System::Console::{
        FlushConsoleInputBuffer, GetStdHandle, STD_INPUT_HANDLE,
    };
    // SAFETY: GetStdHandle takes a constant and returns the process's
    // standard input handle or a sentinel; FlushConsoleInputBuffer takes that
    // handle by value, writes through no pointer, and reports an invalid or
    // non-console handle as a zero return, which is turned into the error.
    // No memory is shared with either call.
    let flushed = unsafe { FlushConsoleInputBuffer(GetStdHandle(STD_INPUT_HANDLE)) };
    match flushed {
        0 => Err(io::Error::last_os_error()),
        _ => Ok(()),
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

/// The key a typed line answers with: its first character past leading
/// blanks, Enter for an empty line, Escape for a line that starts with one,
/// and the end of input where there was no line.
fn line_key(line: Option<&str>) -> io::Result<Pressed> {
    let Some(line) = line else {
        return Err(io::Error::from(io::ErrorKind::UnexpectedEof));
    };
    Ok(match line.trim().chars().next() {
        None => Pressed::Enter,
        Some('\u{1b}') => Pressed::Escape,
        Some(c) => Pressed::Char(c),
    })
}

/// The text a typed line answers with: trimmed, its control characters
/// dropped as the raw read drops them.
fn line_text(line: &str) -> String {
    line.chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .to_owned()
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
/// A typed line that picks nothing draws the buttons again, so the person
/// sees their answer was not taken.
fn asked<T: Copy>(
    style: &Style,
    reading: Reading,
    options: &[(Choice<'_>, T)],
    mut read: impl FnMut() -> io::Result<Pressed>,
    mut draw: impl FnMut(&[String]),
) -> io::Result<T> {
    let shown: Vec<Choice<'_>> = options.iter().map(|(choice, _)| *choice).collect();
    one_default_and_distinct_keys(&shown)?;
    draw(&style.choices(&shown));
    loop {
        match answer(&shown, read())? {
            Answer::Picked(at) => {
                draw(&style.picked(shown[at].label));
                return Ok(options[at].1);
            }
            Answer::Cancel => return Err(io::Error::from(io::ErrorKind::Interrupted)),
            Answer::Ignored => match reading {
                Reading::Keys => {}
                Reading::Lines => draw(&style.choices(&shown)),
            },
        }
    }
}

/// The key read against the choices shown. Letters match either case, so
/// Caps Lock does not turn every key into one the question ignores. A read
/// that failed is the terminal's own error, handed on: read again, a hung
/// up terminal fails again at once and forever.
fn answer(shown: &[Choice<'_>], pressed: io::Result<Pressed>) -> io::Result<Answer> {
    if cancels(&pressed) {
        return Ok(Answer::Cancel);
    }
    let wanted = match pressed? {
        Pressed::Enter => Key::Enter,
        Pressed::Char(c) => Key::Char(c),
        _ => return Ok(Answer::Ignored),
    };
    Ok(shown
        .iter()
        .position(|choice| same(choice.key, wanted))
        .map_or(Answer::Ignored, Answer::Picked))
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

/// Questions driven by scripted keys, for the tests of the verbs that ask
/// them.
#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    fn scripted(keys: &[Pressed]) -> impl FnMut() -> io::Result<Pressed> + '_ {
        let mut keys = keys.iter().cloned();
        move || {
            keys.next()
                .ok_or_else(|| io::Error::from(io::ErrorKind::UnexpectedEof))
        }
    }

    /// A question drawn in `style` and answered by `keys`, in order, read
    /// raw: what it drew, and the answer. Keys run out as the end of input.
    pub fn asked<T: Copy>(
        style: &Style,
        options: &[(Choice<'_>, T)],
        keys: &[Pressed],
    ) -> (Vec<String>, io::Result<T>) {
        let mut drawn = Vec::new();
        let answer = super::asked(style, Reading::Keys, options, scripted(keys), |lines| {
            drawn.extend_from_slice(lines)
        });
        (drawn, answer)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ui::testing::{plain, rich, tagged};

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
    /// input cancel, anything else is ignored, and a read that failed
    /// otherwise is handed on as the error it is.
    #[test]
    fn a_key_picks_the_choice_it_shows() {
        let rows: [(&str, io::Result<Pressed>, Option<Answer>); 11] = [
            ("its key", Ok(Pressed::Char('c')), Some(Answer::Picked(0))),
            (
                "its key in capitals",
                Ok(Pressed::Char('C')),
                Some(Answer::Picked(0)),
            ),
            (
                "a symbol key",
                Ok(Pressed::Char('?')),
                Some(Answer::Picked(1)),
            ),
            ("Enter", Ok(Pressed::Enter), Some(Answer::Picked(2))),
            ("Escape", Ok(Pressed::Escape), Some(Answer::Cancel)),
            ("Ctrl-C", Ok(Pressed::CtrlC), Some(Answer::Cancel)),
            ("the end of input", eof(), Some(Answer::Cancel)),
            (
                "a key not shown",
                Ok(Pressed::Char('x')),
                Some(Answer::Ignored),
            ),
            ("a digit", Ok(Pressed::Char('1')), Some(Answer::Ignored)),
            ("an arrow", Ok(Pressed::ArrowDown), Some(Answer::Ignored)),
            (
                "a read that failed otherwise",
                Err(io::Error::from(io::ErrorKind::BrokenPipe)),
                None,
            ),
        ];
        for (what, pressed, want) in rows {
            let got = answer(&shown(), pressed);
            match want {
                Some(want) => assert_eq!(got.ok(), Some(want), "{what}"),
                None => assert!(
                    got.is_err_and(|error| error.kind() == io::ErrorKind::BrokenPipe),
                    "{what}"
                ),
            }
        }
    }

    /// A read that fails is not read again: the question ends on the
    /// terminal's error after one read.
    #[test]
    fn a_failed_read_ends_the_question() {
        let mut reads = 0;
        let failed = asked(
            &plain(),
            Reading::Keys,
            &CHOICES,
            || {
                reads += 1;
                Err(io::Error::from(io::ErrorKind::BrokenPipe))
            },
            |_| {},
        );
        assert!(failed.is_err_and(|error| error.kind() == io::ErrorKind::BrokenPipe));
        assert_eq!(reads, 1);
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
            &plain(),
            Reading::Keys,
            &[(choice(Key::Char('a')), ())],
            || panic!("a refused question read a key"),
            |lines| panic!("a refused question drew {lines:?}"),
        );
        assert!(refused.is_err());
    }

    /// Ignored keys read on; the answer is the first key that picks, and the
    /// choice it picked is drawn under the buttons. Read raw, a key that
    /// picks nothing draws nothing; read as typed lines, it draws the
    /// buttons again.
    #[test]
    fn an_ignored_key_reads_on_to_the_one_that_picks() {
        let buttons = "  [c] commit them · [?] show everything · [Enter] leave them as diffs";
        for (reading, want) in [
            (Reading::Keys, vec![buttons, "  › commit them"]),
            (
                Reading::Lines,
                vec![buttons, buttons, buttons, "  › commit them"],
            ),
        ] {
            let mut keys = vec![
                Ok(Pressed::Char('x')),
                Ok(Pressed::Char('1')),
                Ok(Pressed::Char('c')),
            ]
            .into_iter();
            let mut drawn = Vec::new();
            let picked = asked(
                &plain(),
                reading,
                &CHOICES,
                || keys.next().unwrap_or_else(eof),
                |lines| drawn.extend_from_slice(lines),
            );
            assert_eq!(picked.ok(), Some('c'), "{reading:?}");
            assert_eq!(drawn, want, "{reading:?}");
            assert!(keys.next().is_none(), "read past the key that picked");
        }
    }

    /// A cancel is the interrupted error the run exits 130 on, and draws no
    /// choice as picked, in either rendering.
    #[test]
    fn escape_cancels_with_nothing_picked() {
        for (style, buttons) in [
            (
                rich(100),
                "  <34>[c]</> <90>commit them</><90> · </><34>[?]</> <90>show everything</><90> · </><1;34>[Enter]</> <1>leave them as diffs</>",
            ),
            (
                plain(),
                "  [c] commit them · [?] show everything · [Enter] leave them as diffs",
            ),
        ] {
            let mut drawn = Vec::new();
            let cancelled = asked(
                &style,
                Reading::Keys,
                &CHOICES,
                || Ok(Pressed::Escape),
                |lines| drawn.extend_from_slice(lines),
            );
            let error = cancelled.expect_err("Escape picked a choice");
            assert!(crate::ui::cancelled(&error), "{error:?}");
            assert_eq!(tagged(&drawn), [buttons]);
        }
    }

    /// The write consent as production draws it, in both renderings: `y`
    /// writes, Enter is the default no. One row per answer.
    #[test]
    fn the_consent_draws_accept_and_decline() {
        let rich_asked = [
            "",
            "<33>!</> <1>write 3 changes?</>",
            "  <34>[y]</> <90>yes</><90> · </><1;34>[Enter]</> <1>no</>",
        ];
        let plain_asked = ["! write 3 changes?", "  [y] yes · [Enter] no"];
        type Row = (&'static str, Pressed, bool, &'static str, &'static str);
        let rows: [Row; 2] = [
            (
                "accept",
                Pressed::Char('y'),
                true,
                "  <34>›</> <1>yes</>",
                "  › yes",
            ),
            (
                "decline",
                Pressed::Enter,
                false,
                "  <34>›</> <1>no</>",
                "  › no",
            ),
        ];
        for (what, key, want, rich_tail, plain_tail) in rows {
            for (style, head, tail) in [
                (rich(100), &rich_asked[..], rich_tail),
                (plain(), &plain_asked[..], plain_tail),
            ] {
                let mut drawn = Vec::new();
                let mut keys = [Ok(key.clone())].into_iter();
                let answer = consented(
                    &style,
                    Reading::Keys,
                    "write 3 changes?",
                    || keys.next().unwrap_or_else(eof),
                    |lines| drawn.extend_from_slice(lines),
                );
                let wanted: Vec<&str> = head.iter().copied().chain([tail]).collect();
                assert_eq!(tagged(&drawn), wanted, "{what}");
                assert_eq!(answer.ok(), Some(want), "{what}");
            }
        }
    }

    /// Where the answers come from: keys on a terminal, typed lines where
    /// stderr is redirected, and a refusal with no terminal on stdin.
    #[test]
    fn a_question_reads_keys_lines_or_nothing() {
        let rows = [
            (true, true, Some(Reading::Keys)),
            (true, false, Some(Reading::Lines)),
            (false, true, None),
            (false, false, None),
        ];
        for (stdin, stderr, want) in rows {
            assert_eq!(
                reading(stdin, stderr).ok(),
                want,
                "stdin {stdin}, stderr {stderr}"
            );
        }
    }

    /// A typed line as a key and as text: its first character past blanks,
    /// Enter for an empty line, Escape for a line that starts with one, the
    /// end of input where there was none; as text, trimmed, control
    /// characters dropped.
    #[test]
    fn a_typed_line_answers_as_its_first_key() {
        let rows: [(Option<&str>, Option<Pressed>); 6] = [
            (Some("y\n"), Some(Pressed::Char('y'))),
            (Some("  yes\n"), Some(Pressed::Char('y'))),
            (Some("\n"), Some(Pressed::Enter)),
            (Some("   \n"), Some(Pressed::Enter)),
            (Some("\u{1b}\n"), Some(Pressed::Escape)),
            (None, None),
        ];
        for (line, want) in rows {
            let got = line_key(line);
            match want {
                Some(want) => assert_eq!(got.ok(), Some(want), "{line:?}"),
                None => assert!(cancels(&got), "{line:?}"),
            }
        }
        assert_eq!(line_text("  fix: renders\n"), "fix: renders");
        assert_eq!(line_text("fix\u{7}: bell\n"), "fix: bell");
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
