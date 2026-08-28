//! The one place a human-facing line leaves the CLI through.
//!
//! The grammar is what every verb already writes in: a line at column 0
//! opens a block, and a line indented by two spaces is detail of the
//! block above it. One set of calls therefore renders two ways — the
//! plain lines a script parses, and a framed, grouped terminal session
//! for a person — without a verb knowing which it is talking to.
//!
//! **A verb is framed only once it opens a frame.** [`intro`] arms the
//! framed rendering; until then every line is plain, terminal or not. A
//! verb that has not been given a frame therefore prints plain lines
//! rather than block glyphs hanging off a gutter that was never drawn,
//! and the frame cannot be left half-open by a call site forgetting to
//! start one.
//!
//! Plain is byte for byte what the same call printed before this module
//! existed. Framing needs a terminal on both streams: a redirected stdout
//! is somebody reading the bytes, whatever stderr is attached to.
//! `KENDEX_UI` takes `plain` or `pretty` and overrides the detection.
//!
//! **Text from a catalog is escaped here, once, line by line.** Every
//! human line can carry a name, a message or a path somebody else wrote,
//! and a control character in one of those rewrites the terminal around
//! it. The printer is the one place that sees all of them, so it escapes
//! what it prints and no call site has to remember to. The escaping is
//! per line, never over the whole message: a caller that wrote a break
//! meant one, and escaping the message whole would hand the reader the
//! two characters `\n` where its paragraph used to be. [`out`] is the
//! exception: it carries JSON and other machine content, and must stay
//! byte-exact.
//!
//! **A line said right before a wait has to be drawn first.** A block is
//! held open until something follows it, so a verb that says where it is
//! going and then blocks would say it after coming back. [`spinner`]
//! draws what is open before it starts, which is why every wait long
//! enough to notice is wrapped in one.

mod blocks;
mod prompt;

pub use blocks::{finish, flush, intro};
pub use prompt::{ask, confirm, spinner};

use kendex_core::names::shown;

use std::io::{IsTerminal, Write};
use std::sync::OnceLock;
use std::sync::atomic::{AtomicBool, Ordering};

use blocks::Tone;

/// How lines reach the reader.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// One line per call, exactly as written.
    Plain,
    /// Framed and grouped, one block per thing said.
    Pretty,
}

/// Whether this run could frame at all: a terminal on both streams, or an
/// override saying so. Read once — a mode that changed mid-run would
/// frame half a session.
fn capable() -> bool {
    static CAPABLE: OnceLock<bool> = OnceLock::new();
    *CAPABLE.get_or_init(|| {
        let asked = std::env::var("KENDEX_UI");
        if let Ok(value) = &asked
            && wanted(value).is_none()
        {
            // Silently falling back would leave a machine framed or plain
            // for a reason nobody could see in the output.
            write_line(&format!(
                "warning: KENDEX_UI={} is not plain, pretty or auto — detecting instead",
                shown(value)
            ));
        }
        asked
            .ok()
            .and_then(|value| wanted(&value))
            .unwrap_or_else(|| {
                both_terminals(
                    std::io::stdout().is_terminal(),
                    std::io::stderr().is_terminal(),
                )
            })
    })
}

/// Framing needs a terminal on both streams. A redirected stdout is
/// somebody reading the bytes, whatever stderr is attached to, and a
/// redirected stderr is where the framing itself would land.
fn both_terminals(stdout: bool, stderr: bool) -> bool {
    stdout && stderr
}

/// What `KENDEX_UI` asked for, if it asked for anything this run knows.
/// `auto` and anything unrecognised leave the answer to the detection.
fn wanted(value: &str) -> Option<bool> {
    match value {
        "plain" => Some(false),
        "pretty" => Some(true),
        _ => None,
    }
}

/// Set by [`intro`], and the only thing that turns framing on.
static FRAMED: AtomicBool = AtomicBool::new(false);

/// Set once a closing line has been drawn — by a ledger the run ended on,
/// by one drawn as an ordinary block because output followed it, or by a
/// failure. A frame opened and never closed leaves the reader a gutter bar
/// hanging off the bottom of the run, so [`finish`] closes what this says
/// is still open.
static CLOSED: AtomicBool = AtomicBool::new(false);

pub fn mode() -> Mode {
    match capable() && FRAMED.load(Ordering::Relaxed) {
        true => Mode::Pretty,
        false => Mode::Plain,
    }
}

/// A message's lines, each escaped on its own. The one place the split
/// happens, so what [`escaped`] returns and what [`tell`] prints cannot
/// drift apart: a break the caller wrote survives, and untrusted text
/// inside a line still cannot act on the terminal.
fn lines(text: &str) -> impl Iterator<Item = String> + '_ {
    text.split('\n').map(shown)
}

/// A message escaped without being flattened.
pub(crate) fn escaped(text: &str) -> String {
    lines(text).collect::<Vec<_>>().join("\n")
}

fn write_line(line: &str) {
    let _ = writeln!(std::io::stderr(), "{line}");
}

/// v1 prints human tables to stderr; stdout stays clean for composition.
/// A verb's own machine-facing content goes here and is never framed —
/// but the block above it is drawn first, so the two streams reach a
/// terminal in the order they were written.
pub fn out(line: &str) {
    flush();
    let _ = writeln!(std::io::stdout(), "{line}");
}

/// One line of human output. Two leading spaces make it detail of the
/// line above; anything else opens a block of its own.
pub fn say(line: &str) {
    tell(Tone::Step, line);
}

/// A line the plan wrote about itself — a note, a skip, a decision.
pub fn note(line: &str) {
    tell(Tone::Info, line);
}

/// A line about something that will not work as the reader expects.
pub fn warn(line: &str) {
    tell(Tone::Warn, line);
}

/// A line about something that did not happen.
pub fn fail(line: &str) {
    tell(Tone::Error, line);
}

/// One message, said a line at a time. A caller's break is a break in
/// both renderings: plain writes the same bytes it always did, and a
/// blank line in the framed one closes the block above it, which is what
/// a caller writing `\n` before a heading was asking for.
fn tell(tone: Tone, text: &str) {
    for line in lines(text) {
        match mode() {
            Mode::Plain => write_line(&line),
            Mode::Pretty => blocks::said(tone, &line),
        }
    }
}

/// How a run ended: the outcome, and the next step under each part of it
/// that has one. Held open — with nothing after it, this is the line the
/// frame closes on rather than one more block inside it.
pub fn ledger(head: &str, steps: &[String]) {
    let head = escaped(head);
    let steps: Vec<String> = steps.iter().map(|step| escaped(step)).collect();
    if mode() == Mode::Plain {
        write_line(&head);
        for step in &steps {
            write_line(&format!("  {step}"));
        }
        return;
    }
    blocks::open(Tone::Done, &head, true, &steps);
}

/// The last line of a run that failed. Plain mode prints what it always
/// printed; a frame closes on it in the failure style.
pub fn outro_fail(line: &str) {
    let line = escaped(line);
    if mode() == Mode::Plain {
        return write_line(&line);
    }
    blocks::fail_frame(&line);
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The override answers for exactly two values. Everything else,
    /// `auto` and a typo alike, leaves the streams to decide.
    #[test]
    fn only_plain_and_pretty_override_the_detection() {
        assert_eq!(wanted("plain"), Some(false));
        assert_eq!(wanted("pretty"), Some(true));
        for ignored in ["auto", "", "Pretty", "1", "true", "plane"] {
            assert_eq!(wanted(ignored), None, "{ignored:?} was read as an answer");
        }
    }

    /// A break the caller wrote is structure and survives; a control
    /// character inside a line is content and does not. Both halves in
    /// one test, because a fix for either one alone regresses the other,
    /// and this is the split `tell` prints through as well.
    #[test]
    fn a_break_survives_the_escaping_and_a_control_character_does_not() {
        // What `kendex diff` writes before every file heading. Escaped
        // whole, the blank line became the two characters a reader sees
        // as a backslash and an n.
        assert_eq!(escaped("\nSKILL.md  +2 -1"), "\nSKILL.md  +2 -1");
        assert_eq!(escaped("first\nsecond\nthird"), "first\nsecond\nthird");
        assert_eq!(escaped("trailing\n"), "trailing\n");
        assert_eq!(escaped(""), "");
        assert_eq!(escaped("\n"), "\n");

        assert_eq!(escaped("we\u{1b}[31mird"), "we\\u{1b}[31mird");
        assert_eq!(
            escaped("one\nwe\u{1b}[31mird\ntwo"),
            "one\nwe\\u{1b}[31mird\ntwo"
        );
        // A tab is a control character too, and a carriage return is the
        // one that would redraw the line the reader is looking at.
        assert_eq!(escaped("a\tb\rc"), "a\\tb\\rc");
    }

    /// One redirected stream is enough to make a run plain: a pipe on
    /// stdout is somebody parsing the bytes, and a pipe on stderr is
    /// where the framing itself would have gone.
    #[test]
    fn one_redirected_stream_is_enough_to_stay_plain() {
        assert!(both_terminals(true, true));
        assert!(!both_terminals(true, false), "a piped stderr still framed");
        assert!(!both_terminals(false, true), "a piped stdout still framed");
        assert!(!both_terminals(false, false));
    }
}
