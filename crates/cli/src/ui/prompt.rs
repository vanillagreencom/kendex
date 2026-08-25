//! The question a run asks, and what it shows while it works.
//!
//! A question carries its own consequence — what a yes does, in the
//! question itself — so the answer is given against the change rather
//! than against the verb's name. Only the widget differs between modes: a
//! framed confirm on a terminal, the typed `[y/N]` everywhere else.

use std::io::Write;

use super::{Mode, mode};

/// Ask. The caller has already established there is somebody to ask: a
/// run needing an answer with no terminal on stdin refuses before its
/// first write rather than reaching this.
pub fn confirm(question: &str) -> std::io::Result<bool> {
    // Whatever is still being said is drawn before the question: a
    // question asked over an undrawn block is asked about the block
    // before it, and the answer decides a write.
    super::flush();
    if mode() == Mode::Pretty {
        return cliclack::confirm(question).initial_value(false).interact();
    }
    let _ = write!(std::io::stderr(), "{question} [y/N] ");
    let mut answer = String::new();
    std::io::stdin().read_line(&mut answer)?;
    Ok(matches!(answer.trim(), "y" | "Y" | "yes"))
}

/// Work in progress, shown while it runs and gone when it ends. Chrome,
/// and only on a terminal: a plain run prints its outcomes and nothing
/// about the waiting in between, which is what keeps its lines the ones
/// a script already parses.
pub struct Task(Option<cliclack::ProgressBar>);

pub fn spinner(label: &str) -> Task {
    if mode() == Mode::Plain {
        return Task(None);
    }
    super::flush();
    let bar = cliclack::spinner();
    bar.start(label);
    Task(Some(bar))
}

impl Drop for Task {
    /// The wait ends when the work does, whether the caller reached the
    /// end of it or returned early: a spinner still ticking under the
    /// next block never stops on its own. Nothing is left behind — what
    /// the work produced is the block that follows, and a line saying it
    /// waited would be one more line in both modes to say the same thing.
    fn drop(&mut self) {
        if let Some(bar) = self.0.take() {
            bar.clear();
        }
    }
}
