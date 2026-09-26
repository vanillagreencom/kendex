//! The spinner a rich run draws while it waits, on the line its result
//! replaces.

use std::convert::Infallible;
use std::io::{IsTerminal, Write};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::Duration;

use super::modes::{Look, Style};

/// How long one frame stays up.
const TICK: Duration = Duration::from_millis(80);

/// A spinner drawn on stderr for as long as this lives. Dropping it stops
/// the drawing thread, waits for it, and clears the line, so whatever the
/// verb prints next — the result — takes the spinner's place. Nothing is
/// drawn unless the run is rich and stderr is a terminal: `KENDEX_UI=pretty`
/// over a pipe still gets no cursor control.
pub struct Spinner {
    /// Never sent on. Dropping it is the stop: the thread's wait ends in a
    /// disconnect.
    stop: Option<Sender<Infallible>>,
    drawing: Option<JoinHandle<()>>,
}

impl Spinner {
    pub fn start(style: &Style, label: &str) -> Spinner {
        let idle = Spinner {
            stop: None,
            drawing: None,
        };
        if !matches!(style.look, Look::Rich { .. }) || !std::io::stderr().is_terminal() {
            return idle;
        }
        // A framed verb's open block lands above the spinner, not under it.
        super::flush();
        let (stop, stopped) = mpsc::channel::<Infallible>();
        let (style, label) = (*style, label.to_owned());
        let drawing = std::thread::spawn(move || {
            let mut tick = 0;
            loop {
                let frame = style.spinner(&label, tick).concat();
                let mut err = std::io::stderr().lock();
                let _ = write!(err, "\r\x1b[2K{frame}");
                let _ = err.flush();
                drop(err);
                match stopped.recv_timeout(TICK) {
                    Err(RecvTimeoutError::Timeout) => tick += 1,
                    Err(RecvTimeoutError::Disconnected) => break,
                    Ok(never) => match never {},
                }
            }
            let mut err = std::io::stderr().lock();
            let _ = write!(err, "\r\x1b[2K");
            let _ = err.flush();
        });
        Spinner {
            stop: Some(stop),
            drawing: Some(drawing),
        }
    }
}

impl Drop for Spinner {
    fn drop(&mut self) {
        drop(self.stop.take());
        if let Some(drawing) = self.drawing.take() {
            // A drawing thread that panicked leaves a line to clear and
            // nothing to recover; the run's own output matters more.
            let _ = drawing.join();
        }
    }
}
