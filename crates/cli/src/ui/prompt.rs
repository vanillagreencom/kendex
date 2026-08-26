//! The question a run asks, and what it shows while it works.
//!
//! A question carries its own consequence — what a yes does, in the
//! question itself — so the answer is given against the change rather
//! than against the verb's name. Both modes ask for the same thing: the
//! word, then Enter. A framed prompt that submitted on one keystroke
//! would let a stray `y` authorise a write, which is not a trade a
//! prettier widget is worth.

use std::io::Write;

use super::{Mode, mode};

/// Ask. The caller has already established there is somebody to ask: a
/// run needing an answer with no terminal on stdin refuses before its
/// first write rather than reaching this.
///
/// The framed prompt is cancelled with `Esc` or `Ctrl-C`. `Ctrl-D` is not
/// one of its answers — a terminal in raw mode delivers it as a byte, not
/// as end of input — and the plain prompt keeps taking it as a no.
pub fn confirm(question: &str) -> std::io::Result<bool> {
    // Whatever is still being said is drawn before the question: a
    // question asked over an undrawn block is asked about the block
    // before it, and the answer decides a write.
    super::flush();
    let asked = format!("{question} [y/N]");
    let answer = match mode() {
        Mode::Pretty => cliclack::input(asked)
            .default_input("N")
            .placeholder("N")
            .interact::<String>()?,
        Mode::Plain => {
            let _ = write!(std::io::stderr(), "{asked} ");
            let mut typed = String::new();
            std::io::stdin().read_line(&mut typed)?;
            typed
        }
    };
    Ok(answered(&answer))
}

/// What counts as a yes. Everything else is a no, the empty line
/// included: a prompt whose default is no has to read a bare Enter, an
/// end of input, and a typo the same way.
fn answered(typed: &str) -> bool {
    matches!(typed.trim(), "y" | "Y" | "yes")
}

/// Work in progress, shown while it runs and gone when it ends. Chrome,
/// and only on a terminal: a plain run prints its outcomes and nothing
/// about the waiting in between, which is what keeps its lines the ones
/// a script already parses.
///
/// Starting one draws whatever block is open, which is the other half of
/// its job: a verb that says where it is going and then waits would
/// otherwise say it on the way back.
pub struct Task(Option<cliclack::ProgressBar>);

pub fn spinner(label: &str) -> Task {
    super::flush();
    if mode() == Mode::Plain {
        return Task(None);
    }
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

#[cfg(test)]
mod tests {
    use super::answered;

    #[test]
    fn only_a_typed_yes_is_a_yes() {
        for yes in ["y", "Y", "yes", "y\n", " y \r\n"] {
            assert!(answered(yes), "{yes:?} was not read as a yes");
        }
        // The empty line is a bare Enter, and the framed prompt turns a
        // bare Enter into its default; the end of input plain mode reads
        // on Ctrl-D arrives the same way.
        for no in ["", "\n", "n", "N", "no", "Yes", "YES", "ye", "1", "  "] {
            assert!(!answered(no), "{no:?} authorised a write");
        }
    }
}
