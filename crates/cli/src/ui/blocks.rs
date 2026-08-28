//! The block a run is in the middle of saying, and the frame around it.
//!
//! A headline is held open rather than drawn where it was said, so the
//! lines indented under it are drawn with it instead of as blocks of
//! their own, and so a closing ledger with nothing after it can become
//! the frame's last line instead of one more block inside it. Everything
//! that would land beside an undrawn block — the other stream, a prompt,
//! a wait — calls [`flush`] first.
//!
//! The frame itself is opened once, by [`intro`], and closed once, by
//! whatever ends the run. A frame opened and left open hangs a gutter bar
//! off the bottom of the output, so what closed it is recorded rather
//! than assumed.

use std::sync::atomic::Ordering;
use std::sync::{Mutex, MutexGuard, OnceLock};

use super::{CLOSED, FRAMED, Mode, capable, mode};

/// Which symbol a block opens with. Plain mode has no use for it: the
/// text carries its own `warning:`/`note:` prefix and always did.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(super) enum Tone {
    Step,
    Info,
    Warn,
    Error,
    Done,
}

/// A block that has been said and not yet drawn.
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

/// The last line of a run that failed. Plain mode prints what it always
/// printed; a frame closes on it in the failure style.
pub(super) fn fail_frame(line: &str) {
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

/// One line into the framed rendering: detail of the block above it where
/// it was written as detail, a block of its own otherwise.
pub(super) fn said(tone: Tone, line: &str) {
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

pub(super) fn open(tone: Tone, head: &str, ledger: bool, steps: &[String]) {
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
