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
//! **Text from a catalog is escaped here, once.** Every human line can
//! carry a name, a message or a path somebody else wrote, and a control
//! character in one of those rewrites the terminal around it. The printer
//! is the one place that sees all of them, so it escapes what it prints
//! and no call site has to remember to. [`out`] is the exception: it
//! carries JSON and other machine content, and must stay byte-exact.
//!
//! **A line said right before a wait has to be drawn first.** A block is
//! held open until something follows it, so a verb that says where it is
//! going and then blocks would say it after coming back. [`spinner`]
//! draws what is open before it starts, which is why every wait long
//! enough to notice is wrapped in one.

mod prompt;

pub use prompt::{confirm, spinner};

use kendex_core::names::shown;

use std::io::{IsTerminal, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};

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

/// Which symbol a block opens with. Plain mode has no use for it: the
/// text carries its own `warning:`/`note:` prefix and always did.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Tone {
    Step,
    Info,
    Warn,
    Error,
    Done,
}

/// A block that has been said and not yet drawn. Held open so the lines
/// indented under its headline are drawn with it rather than as blocks of
/// their own, and so a closing ledger with nothing after it can become
/// the frame's last line instead of one more block inside it.
struct Pending {
    head: String,
    /// Everything under the headline, carrying the indent it was written
    /// with. A run of headlines with nothing under any of them is one
    /// group rather than one block each: a tick per installation, each
    /// walled off by its own blank rule, is the wall this module exists
    /// to stop printing.
    lines: Vec<String>,
    /// Whether any of those lines is detail rather than another headline.
    /// A block something was written under has said what it groups.
    detailed: bool,
    /// The next step under each part of a closing ledger.
    steps: Vec<String>,
    tone: Tone,
    ledger: bool,
}

impl Pending {
    /// Whether another headline of this tone belongs in this block.
    fn takes(&self, tone: Tone, ledger: bool) -> bool {
        !self.ledger && !ledger && !self.detailed && self.tone == tone
    }
}

fn pending() -> MutexGuard<'static, Option<Pending>> {
    static PENDING: OnceLock<Mutex<Option<Pending>>> = OnceLock::new();
    let cell = PENDING.get_or_init(|| Mutex::new(None));
    // A panic while a block was open leaves the block, not the process:
    // the remaining output is worth more than the lock's poison flag.
    cell.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
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
    tell(Tone::Step, &shown(line));
}

/// A line the plan wrote about itself — a note, a skip, a decision.
pub fn note(line: &str) {
    tell(Tone::Info, &shown(line));
}

/// A line about something that will not work as the reader expects.
pub fn warn(line: &str) {
    tell(Tone::Warn, &shown(line));
}

/// A line about something that did not happen.
pub fn fail(line: &str) {
    tell(Tone::Error, &shown(line));
}

fn tell(tone: Tone, line: &str) {
    if mode() == Mode::Plain {
        return write_line(line);
    }
    if line.is_empty() {
        return flush();
    }
    // Both of these take the lock and give it back inside themselves;
    // nothing here holds it across a call that takes it again.
    if let Some(detail) = line.strip_prefix("  ")
        && attach(detail)
    {
        return;
    }
    open(tone, line, false, &[]);
}

/// Open the frame. Nothing is framed until this runs, so a verb that
/// wants the framed rendering asks for it once, at its start.
pub fn intro(title: &str) {
    if !capable() {
        return;
    }
    cliclack::set_theme(Kendex);
    FRAMED.store(true, Ordering::Relaxed);
    let _ = cliclack::intro(title);
}

/// The frame, with the blank rule between blocks taken out. A run's
/// blocks are already told apart by the symbol each one opens with, and a
/// rule drawn between every one of them doubles the height of a listing
/// whose whole point is that it fits on a screen.
struct Kendex;

impl cliclack::Theme for Kendex {
    fn format_log(&self, text: &str, symbol: &str) -> String {
        self.format_log_with_spacing(text, symbol, false)
    }
}

/// How a run ended: the outcome, and the next step under each part of it
/// that has one. Held open — with nothing after it, this is the line the
/// frame closes on rather than one more block inside it.
pub fn ledger(head: &str, steps: &[String]) {
    let head = shown(head);
    let steps: Vec<String> = steps.iter().map(|step| shown(step)).collect();
    if mode() == Mode::Plain {
        write_line(&head);
        for step in &steps {
            write_line(&format!("  {step}"));
        }
        return;
    }
    open(Tone::Done, &head, true, &steps);
}

/// The last line of a run that failed. Plain mode prints what it always
/// printed; a frame closes on it in the failure style.
pub fn outro_fail(line: &str) {
    let line = shown(line);
    if mode() == Mode::Plain {
        return write_line(&line);
    }
    flush();
    CLOSED.store(true, Ordering::Relaxed);
    let _ = cliclack::outro_cancel(line);
}

/// Draw whatever is still open, and close the frame. A ledger nothing
/// followed becomes the closing line itself; a run whose ledger was
/// already drawn — because output followed it — closes on a bare corner,
/// since the frame it opened has to end somewhere.
pub fn finish() {
    if mode() == Mode::Plain {
        return;
    }
    if let Some(block) = pending().take() {
        draw(&block, true);
    }
    if FRAMED.load(Ordering::Relaxed) && !CLOSED.swap(true, Ordering::Relaxed) {
        // Nothing left to say that has not been said: cliclack draws the
        // corner and no text, which is the frame ending rather than one
        // more line of output invented to end it.
        let _ = cliclack::outro("");
    }
}

fn open(tone: Tone, head: &str, ledger: bool, steps: &[String]) {
    let grouped = match pending().as_mut() {
        Some(block) if block.takes(tone, ledger) => {
            block.lines.push(head.to_owned());
            true
        }
        _ => false,
    };
    if grouped {
        return;
    }
    flush();
    *pending() = Some(Pending {
        head: head.to_owned(),
        lines: Vec::new(),
        detailed: false,
        steps: steps.to_vec(),
        tone,
        ledger,
    });
}

/// Put a line under the block that is open, and say whether there was
/// one: an indented line with no headline above it is a headline of its
/// own, however it was written.
fn attach(detail: &str) -> bool {
    match pending().as_mut() {
        Some(block) => {
            block.lines.push(format!("  {detail}"));
            block.detailed = true;
            true
        }
        None => false,
    }
}

/// Draw what is open, so that whatever comes next — a prompt, a wait, a
/// line on the other stream — does not land above it.
pub fn flush() {
    if mode() == Mode::Plain {
        return;
    }
    if let Some(block) = pending().take() {
        draw(&block, false);
    }
}

/// One block, drawn. Detail keeps the two spaces it was written with, so
/// the hierarchy the caller wrote survives the framing. `last` closes the
/// frame, which only a ledger does: a run that ends on anything else ends
/// without a closing line rather than inventing one.
fn draw(block: &Pending, last: bool) {
    let mut text = block.head.clone();
    for line in &block.lines {
        text.push('\n');
        text.push_str(line);
    }
    // A ledger's next steps are detail of its head, wherever it is drawn.
    // The closing line has no gutter to hang them from — the frame ends on
    // it — so they are indented past its own symbol instead, which puts
    // them exactly where the plain rendering puts them: under the head.
    let under = match block.ledger && last {
        true => "\n     ",
        false => "\n  ",
    };
    for step in &block.steps {
        text.push_str(under);
        text.push_str(step);
    }
    let _ = match block.ledger && last {
        true => {
            CLOSED.store(true, Ordering::Relaxed);
            cliclack::outro(&text)
        }
        false => match block.tone {
            Tone::Step => cliclack::log::step(&text),
            Tone::Info => cliclack::log::info(&text),
            Tone::Warn => cliclack::log::warning(&text),
            Tone::Error => cliclack::log::error(&text),
            Tone::Done => cliclack::log::success(&text),
        },
    };
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
