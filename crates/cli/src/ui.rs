//! The one place a human-facing line leaves the CLI through.
//!
//! The grammar is what every verb already writes in: a line at column 0
//! opens a block, and a line indented by two spaces is detail of the
//! block above it. One set of calls therefore renders two ways — the
//! plain lines a script parses, and a framed, grouped terminal session
//! for a person — without a verb knowing which it is talking to.
//!
//! Plain is what anything but a terminal gets, byte for byte what the
//! same call printed before this module existed. Both streams have to be
//! a terminal for the framed rendering: a redirected stdout is somebody
//! reading the bytes, whatever stderr is attached to. `KENDEX_UI` takes
//! `plain` or `pretty` and overrides the detection.

mod prompt;

pub use prompt::{confirm, spinner};

use std::io::{IsTerminal, Write};
use std::sync::{Mutex, MutexGuard, OnceLock};

/// How lines reach the reader.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    /// One line per call, exactly as written.
    Plain,
    /// Framed and grouped, one block per thing said.
    Pretty,
}

/// Read once: a mode that changed mid-run would frame half a session.
/// The theme is settled here too, so a verb that draws a block without
/// opening a frame draws it in the same one as everything else.
pub fn mode() -> Mode {
    static MODE: OnceLock<Mode> = OnceLock::new();
    *MODE.get_or_init(|| {
        let chosen = match std::env::var("KENDEX_UI").as_deref() {
            Ok("plain") => Mode::Plain,
            Ok("pretty") => Mode::Pretty,
            _ => match std::io::stdout().is_terminal() && std::io::stderr().is_terminal() {
                true => Mode::Pretty,
                false => Mode::Plain,
            },
        };
        if chosen == Mode::Pretty {
            cliclack::set_theme(Kendex);
        }
        chosen
    })
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
    /// The next step under each part of a closing ledger.
    steps: Vec<String>,
    tone: Tone,
    ledger: bool,
}

impl Pending {
    /// Whether another headline of this tone belongs in this block. A
    /// block anything is written under has said what it groups, and the
    /// next headline starts its own.
    fn takes(&self, tone: Tone, ledger: bool) -> bool {
        !self.ledger
            && !ledger
            && self.tone == tone
            && self.lines.iter().all(|line| !line.starts_with(' '))
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

/// The headline of the session, printed before anything it frames.
pub fn intro(title: &str) {
    if mode() == Mode::Pretty {
        let _ = cliclack::intro(title);
    }
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
    if mode() == Mode::Plain {
        write_line(head);
        for step in steps {
            write_line(&format!("  {step}"));
        }
        return;
    }
    open(Tone::Done, head, true, steps);
}

/// The last line of a run that failed. Plain mode prints what it always
/// printed; a frame closes on it in the failure style.
pub fn outro_fail(line: &str) {
    if mode() == Mode::Plain {
        return write_line(line);
    }
    flush();
    let _ = cliclack::outro_cancel(line);
}

/// Draw whatever is still open. A ledger nothing followed is the frame's
/// closing line; anything else is a block, and the frame simply ends.
pub fn finish() {
    if mode() == Mode::Plain {
        return;
    }
    let Some(block) = pending().take() else {
        return;
    };
    if !block.ledger {
        return draw(&block);
    }
    let _ = match block.steps.is_empty() {
        true => cliclack::outro(&block.head),
        false => cliclack::outro_note(&block.head, block.steps.join("\n")),
    };
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
            true
        }
        None => false,
    }
}

fn flush() {
    if mode() == Mode::Plain {
        return;
    }
    if let Some(block) = pending().take() {
        draw(&block);
    }
}

/// One block, drawn. Detail keeps the two spaces it was written with, so
/// the hierarchy the caller wrote survives the framing.
fn draw(block: &Pending) {
    let mut text = block.head.clone();
    for line in &block.lines {
        text.push('\n');
        text.push_str(line);
    }
    let _ = match block.tone {
        Tone::Step => cliclack::log::step(&text),
        Tone::Info => cliclack::log::info(&text),
        Tone::Warn => cliclack::log::warning(&text),
        Tone::Error => cliclack::log::error(&text),
        // A ledger that something followed is still the run's outcome,
        // and its next steps still belong in a box under it.
        Tone::Done => match block.steps.is_empty() {
            true => cliclack::log::success(&text),
            false => cliclack::note(&text, block.steps.join("\n")),
        },
    };
}
