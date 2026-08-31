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
//! **A line is escaped here.** Names, paths and messages off a catalog, a
//! lock or a tree kendex did not write reach a terminal through these
//! functions, where a control character would move the cursor or colour
//! the line. [`say`] and its siblings each print one line and escape the
//! whole of it, breaks included: a break inside a value is content, so a
//! name carrying one is a name and not two lines. Structure is said by
//! calling more than once.
//!
//! **A refusal that owns its own breaks is split before it is escaped**, so
//! the breaks reach the reader as breaks. No call site chooses that: the
//! error does, through [`outro_refusal`] and [`fail_refusal`], which take
//! the error rather than its text and route on `refusal`'s own
//! `owns_its_breaks`. What that names is the door's whole membership, and
//! each member carries the obligation that comes with it — every value
//! interpolated into such a message is escaped where it was composed,
//! because a break inside one would become a line of its own here.
//!
//! A type carries that obligation where it can, because a sentence here is
//! what `commands::verify` skipped. `CoreError::ManifestInvalid` holds
//! `manifest::Finding`, whose `Display` escapes all three of its parts, so
//! a constructor cannot hand it text nobody escaped. `CoreError::TomlParse`
//! cannot be typed the same way — its breaks are a parser's caret diagram —
//! so it escapes the path it names in its own `Display` and leaves the rest
//! to `toml`, which every constructor of it hands the whole message; a
//! constructor passing anything else is what `grep -rn "TomlParse {"
//! crates/core/src` would show. The CLI's own [`Lines`] wraps text a verb
//! composed, and `grep -rn "Lines(" crates/cli/src` names every verb that
//! does. All three escape with `kendex_core::names::shown`, which
//! [`escaped`] is the CLI's spelling of. Everything else is a sentence
//! carrying values nobody escaped, and is said as one line.
//!
//! Core escapes elsewhere for its own surfaces (the app reads
//! `names::shown` output directly, and `drift::report::text` bounds and
//! scrubs the report the check verb composes); those are already-safe
//! bytes by the time they arrive, and the escape is idempotent.
//!
//! A sentence is not the only thing a verb prints. What a reader asked to
//! see — a package's file, its readme — goes out through [`payload`], and
//! a serialized answer for a program through [`answer`]; both are the
//! bytes themselves, and escaping either would hand back one line of
//! literal `\n` instead of the thing. Those two honour a break: they are
//! said a line at a time, so a file's lines are lines in both renderings.
//!
//! **A line said right before a wait has to be drawn first.** A block is
//! held open until something follows it, so a verb that says where it is
//! going and then blocks would say it after coming back. [`spinner`]
//! draws what is open before it starts, which is why every wait long
//! enough to notice is wrapped in one.

mod blocks;
mod prompt;
mod refusal;

pub use blocks::{finish, flush, intro};
pub use prompt::{ask, cancelled, confirm, spinner};
pub use refusal::{Lines, fail_refusal, outro_fail, outro_refusal};

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
            && !named_a_mode(value)
        {
            // Silently falling back would leave a machine framed or plain
            // for a reason nobody could see in the output. `auto` is not
            // that case: it asks for the detection by name and gets it,
            // so warning about it would put a line on every run of a
            // machine that spelled its choice out.
            //
            // The value came off the environment, so it is escaped here
            // like any other foreign fragment.
            write_line(&escaped(&format!(
                "warning: KENDEX_UI={value} is not plain, pretty or auto — detecting instead"
            )));
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

/// What `KENDEX_UI` asked for, if it asked for a rendering by name.
/// `auto` and anything unrecognised both leave the answer to the
/// detection, which is why this cannot tell them apart on its own.
fn wanted(value: &str) -> Option<bool> {
    match value {
        "plain" => Some(false),
        "pretty" => Some(true),
        _ => None,
    }
}

/// Whether the value names a mode this run knows. [`wanted`] answers
/// `None` for `auto` and for a typo alike — both leave it to the
/// detection — so the difference between asking for the detection and
/// misspelling a rendering is drawn here, and only the second is worth a
/// line on every run.
fn named_a_mode(value: &str) -> bool {
    value == "auto" || wanted(value).is_some()
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

pub(super) fn write_line(line: &str) {
    let _ = writeln!(std::io::stderr(), "{line}");
}

/// Text made safe to print: control characters and the invisible or
/// direction-flipping ones are shown as their own escapes rather than
/// acted on. Every line [`say`] and its siblings print goes through it,
/// which is why an ordinary call site composes its line out of raw names
/// and leaves the escape here.
///
/// It is `pub` for the other half of the rule: a refusal that owns its line
/// breaks escapes the values it interpolates itself, because a break inside
/// one of those would become a line of its own where it prints.
///
/// Idempotent on its own output: an escape is backslashes and letters,
/// and neither is escaped again.
pub fn escaped(text: &str) -> String {
    kendex_core::names::shown(text)
}

/// v1 prints human tables to stderr; stdout stays clean for composition.
/// A sentence a verb puts on stdout goes here and is never framed — but
/// the block above it is drawn first, so the two streams reach a terminal
/// in the order they were written. What a program parses goes through
/// [`answer`], which escapes nothing.
pub fn out(line: &str) {
    flush();
    let _ = writeln!(std::io::stdout(), "{}", escaped(line));
}

/// A serialized answer for whatever is reading stdout — JSON a verb built,
/// or the lines another program already wrote. Its own escaping authority:
/// JSON spells a control character as its own escape, and running that
/// through [`escaped`] would break the pretty printing into one line of
/// literal `\n` and spell a zero-width character as something no JSON
/// parser reads.
pub fn answer(text: &str) {
    flush();
    let _ = writeln!(std::io::stdout(), "{text}");
}

/// What the reader asked to be shown: a package's file, a readme. Printed
/// as itself, because the bytes are the whole feature — escaped the way a
/// value in a sentence is, `show --file` hands back one line of literal
/// `\n` instead of the file.
pub fn payload(text: &str) {
    for line in text.split('\n') {
        drawn(Tone::Step, line);
    }
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

/// One composed line, escaped at the seam and then said. Nothing survives
/// the escape that could break it in two, so a line is a line however
/// hostile the values inside it are.
fn tell(tone: Tone, text: &str) {
    drawn(tone, &escaped(text));
}

/// One line of a refusal, already escaped. The refusal doors compose their
/// own lines, so this is the one draw that does not escape what it is
/// given.
pub(super) fn drawn_fail(line: &str) {
    drawn(Tone::Error, line);
}

/// One line, already fit to print. Plain writes the same bytes it always
/// did; the framed rendering groups it, and an empty line closes the block
/// above it.
fn drawn(tone: Tone, line: &str) {
    match mode() {
        Mode::Plain => write_line(line),
        Mode::Pretty => blocks::said(tone, line),
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

    /// `auto` asks for the detection by name and gets it, so it is not a
    /// value to warn about: a machine that spells its choice out would
    /// otherwise carry a warning line on every single run. A typo leaves
    /// the answer to the detection too, and that one has to be said out
    /// loud, since nothing else would show the value was ignored.
    #[test]
    fn auto_is_a_mode_and_a_typo_is_not() {
        for named in ["plain", "pretty", "auto"] {
            assert!(named_a_mode(named), "{named:?} was read as a typo");
        }
        for typo in ["", "Pretty", "AUTO", "1", "true", "plane", "auto "] {
            assert!(!named_a_mode(typo), "{typo:?} passed as a mode");
        }
    }

    /// Core composes some of its own refusals with the same escape before
    /// they ever reach a verb, so the seam runs over text that is already
    /// escaped. Escaping it twice has to be escaping it once — otherwise
    /// every such message reaches the reader with its backslashes doubled.
    #[test]
    fn escaping_what_is_already_escaped_changes_nothing() {
        for raw in ["gh\u{1b}[31m", "a\nb", "pay\u{202e}gnp", "plain-name", ""] {
            let once = escaped(raw);
            assert_eq!(escaped(&once), once, "{raw:?}");
            assert!(!once.contains('\u{1b}'), "{once:?}");
        }
    }

    /// The two doors, and the difference between them. A break in a value
    /// is content and is escaped with the rest, so a name cannot become
    /// two lines; a break a message wrote is structure and is a break, so
    /// an error naming one finding per line reaches the reader that way.
    #[test]
    fn a_value_keeps_its_break_and_a_message_keeps_its_own() {
        // What `say` does to its argument: one line, whatever it holds.
        assert_eq!(escaped("a\nb"), "a\\nb");
        // What `lines` does to the same text: two lines, each escaped.
        let split: Vec<String> = "a\u{1b}[31m\nb".split('\n').map(escaped).collect();
        assert_eq!(split, vec!["a\\u{1b}[31m".to_owned(), "b".to_owned()]);
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
