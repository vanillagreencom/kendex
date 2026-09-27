//! The questions a verb not yet converted asks, and what a run shows while
//! it works. A converted verb asks through `keys` instead.
//!
//! A question carries its own consequence — what a yes does, in the
//! question itself — so the answer is given against the change rather
//! than against the verb's name. Both modes here ask for the same thing:
//! the word, then Enter. The keyed read answers on one key, and its
//! default, the key a stray press is likeliest to be, never writes.

use std::io::Write;

use super::modes::{Look, style};
use super::{Mode, escaped, mode};

/// Whether a question is the terminal's widget rather than a typed line.
/// A framed verb asks inside its frame, and a verb drawn from the
/// components asks the same widget wherever it draws rich: the widget is
/// what reads Esc and Ctrl-C as a cancel the verb can finish after, where
/// a typed line on a terminal is ended by the signal with the run half
/// said.
fn widget() -> bool {
    mode() == Mode::Pretty || matches!(style().look, Look::Rich { .. })
}

/// Ask. The caller has already established there is somebody to ask: a
/// run needing an answer with no terminal on stdin refuses before its
/// first write rather than reaching this.
///
/// This and the keyed read in `keys` are the only places the CLI reads
/// from a person, and each draws whatever block is still open before it
/// reads.
///
/// The framed prompt is cancelled with `Esc` or `Ctrl-C`. `Ctrl-D` is not
/// one of its answers — a terminal in raw mode delivers it as a byte, not
/// as end of input — and the plain prompt keeps taking it as a no.
pub fn confirm(question: &str) -> std::io::Result<bool> {
    // Whatever is still being said is drawn before the question: a
    // question asked over an undrawn block is asked about the block
    // before it, and the answer decides a write.
    super::flush();
    // A question names what a yes writes, and what it names comes off a
    // catalog or a tree kendex did not write — so it is escaped where
    // every other sentence is.
    let asked = escaped(&format!("{question} [y/N]"));
    let answer = match widget() {
        true => cliclack::input(asked)
            .default_input("N")
            .placeholder("N")
            .interact::<String>()?,
        false => {
            let _ = write!(std::io::stderr(), "{asked} ");
            let mut typed = String::new();
            std::io::stdin().read_line(&mut typed)?;
            typed
        }
    };
    Ok(answered(&answer))
}

/// Whether an error is a run its user cancelled.
///
/// Two readers make one, and this is the one place that says what it
/// means. A plain prompt here lets SIGINT kill the process and the shell
/// reports 130 itself, while the framed widget reads keys in raw mode,
/// where Ctrl-C arrives as a byte and comes back as an interrupted read.
/// The keyed read in `keys` returns the same interrupted error for Escape,
/// Ctrl-C and the end of input.
pub fn cancelled(error: &(dyn std::error::Error + 'static)) -> bool {
    error
        .downcast_ref::<std::io::Error>()
        .is_some_and(|error| error.kind() == std::io::ErrorKind::Interrupted)
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
///
/// A framed verb's wait is drawn in its frame; any other verb's is the
/// design system's [`super::Spinner`], which draws only where the run is
/// rich.
pub enum Task {
    Framed(cliclack::ProgressBar),
    Drawn(
        #[expect(
            dead_code,
            reason = "held for its drop, which stops the drawing and clears the line"
        )]
        super::Spinner,
    ),
}

pub fn spinner(label: &str) -> Task {
    super::flush();
    if mode() == Mode::Plain {
        return Task::Drawn(super::Spinner::start(&style(), label));
    }
    let bar = cliclack::spinner();
    bar.start(escaped(label));
    Task::Framed(bar)
}

impl Drop for Task {
    /// The wait ends when the work does, whether the caller reached the
    /// end of it or returned early: a spinner still ticking under the
    /// next block never stops on its own. Nothing is left behind — what
    /// the work produced is the block that follows, and a line saying it
    /// waited would be one more line in both modes to say the same thing.
    fn drop(&mut self) {
        if let Task::Framed(bar) = self {
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

#[cfg(test)]
mod cancel_tests {
    use super::cancelled;

    /// A cancel is the one failure that is not one, so nothing but the
    /// read that makes it may be read as one: an ordinary error still has
    /// to exit 1.
    #[test]
    fn only_an_interrupted_read_is_a_cancel() {
        let stopped: Box<dyn std::error::Error> =
            Box::new(std::io::Error::from(std::io::ErrorKind::Interrupted));
        assert!(cancelled(stopped.as_ref()));

        for other in [
            std::io::ErrorKind::NotFound,
            std::io::ErrorKind::PermissionDenied,
            std::io::ErrorKind::UnexpectedEof,
        ] {
            let error: Box<dyn std::error::Error> = Box::new(std::io::Error::from(other));
            assert!(!cancelled(error.as_ref()), "{other:?} read as a cancel");
        }

        let message: Box<dyn std::error::Error> =
            "cancelled — these changes were not written".into();
        assert!(
            !cancelled(message.as_ref()),
            "a message saying cancelled read as one"
        );
    }
}
