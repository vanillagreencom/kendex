//! Running the binary with a terminal on stderr instead of a pipe.
//!
//! The caller builds the command — its home, its arguments, its
//! environment — and this wires the terminal into it, so neither suite
//! inherits the other's rendering variables.
//!
//! Under `tests/support/`, declared once by `tests/main.rs`.
#![cfg(unix)]

use std::process::{Command, Output};

/// Everything the terminal was sent, colour codes and redraws included,
/// with `input` typed before anything was drawn.
#[allow(
    dead_code,
    reason = "including suites use it; the expects are fixture preconditions"
)]
pub fn sent_to_a_terminal(command: Command, input: &[u8]) -> Output {
    let typed = String::from_utf8_lossy(input);
    conversation(command, &[("", &typed)], Stderr::Terminal)
}

/// Where the binary's stderr goes while the terminal is its stdin.
#[allow(dead_code, reason = "including suites use it")]
pub enum Stderr {
    /// The terminal: what it draws is what the terminal was sent.
    Terminal,
    /// A pipe, as in `2>&1 | tee log`: questions are answered by lines.
    Pipe,
}

#[allow(clippy::expect_used, reason = "fixture preconditions")]
fn open_terminal(stderr: &Stderr) -> (std::os::fd::OwnedFd, std::os::fd::OwnedFd) {
    let controller =
        rustix::pty::openpt(rustix::pty::OpenptFlags::RDWR | rustix::pty::OpenptFlags::NOCTTY)
            .expect("a pseudoterminal");
    rustix::pty::grantpt(&controller).expect("granted");
    rustix::pty::unlockpt(&controller).expect("unlocked");
    let name = rustix::pty::ptsname(&controller, Vec::new()).expect("its name");
    let terminal = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(name.to_str().expect("a utf-8 device name"))
        .expect("the terminal side opens");
    if matches!(stderr, Stderr::Terminal) {
        // console enters raw mode after drawing the question. This fixture
        // has no foreground process group to receive terminal signals, so
        // Ctrl-C arriving before that switch would be discarded. Keep it
        // queued as input; canonical mode still needs the child's raw read.
        let mut modes = rustix::termios::tcgetattr(&terminal).expect("terminal modes");
        modes.local_modes.remove(rustix::termios::LocalModes::ISIG);
        rustix::termios::tcsetattr(&terminal, rustix::termios::OptionalActions::Now, &modes)
            .expect("terminal input keeps interrupt keys");
    }
    (controller, terminal.into())
}

/// A run answered one step at a time. Each step's answer is typed once its
/// marker has been drawn after the previous step's, so an answer reaches
/// the question it is for rather than one drawn before it, which drops what
/// was typed ahead. An empty marker types at once.
///
/// Reading runs until the last writer closes, which on Linux arrives as
/// `EIO` rather than end of file. Stdout goes nowhere: only the terminal is
/// under test, and a pipe nobody drains deadlocks the pair once a chattier
/// verb fills its buffer.
///
/// A run still going after [`DEADLINE`] is killed, so a question nobody
/// answers fails its test instead of holding the suite forever.
///
/// The command is taken by value and dropped before the read, because a
/// `Command` holds the handles it was given until it is: left alive, it is
/// a writer on the terminal that never closes, and the read below runs
/// until the suite is killed.
#[allow(
    dead_code,
    clippy::expect_used,
    reason = "including suites use it; the expects are fixture preconditions"
)]
pub fn conversation(mut command: Command, steps: &[(&str, &str)], stderr: Stderr) -> Output {
    use std::fs;
    use std::io::{Read, Write};
    let (controller, terminal) = open_terminal(&stderr);

    command
        .stdin(std::process::Stdio::from(
            terminal.try_clone().expect("a second handle"),
        ))
        .stdout(std::process::Stdio::null());
    match stderr {
        Stderr::Terminal => command.stderr(std::process::Stdio::from(
            terminal.try_clone().expect("a third handle"),
        )),
        Stderr::Pipe => command.stderr(std::process::Stdio::piped()),
    };
    let mut child = command.spawn().expect("kendex binary runs");
    // Every handle the parent still holds goes now, or the read below never
    // ends: the terminal stays open as long as any writer holds it, and the
    // command holds the three it was handed.
    drop(terminal);
    drop(command);

    // The child is waited on only after `stop` is sent, so the pid the
    // watchdog kills is still this child's, alive or not yet reaped.
    let (stop, stopped) = std::sync::mpsc::channel::<()>();
    let pid = rustix::process::Pid::from_child(&child);
    let watchdog = std::thread::spawn(move || {
        if let Err(std::sync::mpsc::RecvTimeoutError::Timeout) = stopped.recv_timeout(DEADLINE) {
            let _ = rustix::process::kill_process(pid, rustix::process::Signal::KILL);
        }
    });

    let mut writer = fs::File::from(controller);
    let mut reader: Box<dyn Read> = match stderr {
        Stderr::Terminal => Box::new(writer.try_clone().expect("a reading handle")),
        Stderr::Pipe => Box::new(child.stderr.take().expect("the piped stderr")),
    };
    let mut sent = Vec::new();
    let mut buffer = [0u8; 4096];
    let mut from = 0;
    let mut steps = steps.iter();
    let mut next = steps.next();
    loop {
        while let Some((marker, answer)) = next {
            let Some(at) = found(&sent[from..], marker.as_bytes()) else {
                break;
            };
            from += at + marker.len();
            writer.write_all(answer.as_bytes()).expect("terminal input");
            next = steps.next();
        }
        match Read::read(&mut reader, &mut buffer) {
            Ok(0) => break,
            Ok(read) => sent.extend_from_slice(&buffer[..read]),
            // A signal arriving mid-read is not the end of the stream.
            // Taking it for one cuts the capture short without saying so.
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break,
        }
    }
    drop(stop);
    let _ = watchdog.join();
    Output {
        status: child.wait().expect("the child exits"),
        stdout: Vec::new(),
        stderr: sent,
    }
}

/// How long a run may take: generous against a slow runner, and short
/// beside a suite that would otherwise never end.
const DEADLINE: std::time::Duration = std::time::Duration::from_secs(120);

/// Where `marker` first starts in `drawn`; an empty marker at once.
fn found(drawn: &[u8], marker: &[u8]) -> Option<usize> {
    match marker.is_empty() {
        true => Some(0),
        false => drawn
            .windows(marker.len())
            .position(|window| window == marker),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};

    /// Queue Ctrl-C before the raw-mode switch, as a prompt's marker can
    /// cause the fixture to do. The piped mode is the must-fail control:
    /// its terminal consumes Ctrl-C and flushes input before the newline.
    #[test]
    #[allow(clippy::expect_used, reason = "fixture preconditions")]
    fn an_interrupt_queued_before_the_raw_read_remains_input() {
        for (stderr, wanted) in [(Stderr::Terminal, b'\x03'), (Stderr::Pipe, b'\n')] {
            let (controller, terminal) = open_terminal(&stderr);
            let mut writer = std::fs::File::from(controller);
            writer.write_all(b"\x03\n").expect("queued interrupt");
            // A PTY write can return before its input is processed. Wait
            // for the canonical line to be readable before changing modes.
            let started = std::time::Instant::now();
            while rustix::io::ioctl_fionread(&terminal).expect("queued input size") == 0 {
                assert!(started.elapsed() < DEADLINE, "terminal input deadline");
                std::thread::yield_now();
            }
            let mut modes = rustix::termios::tcgetattr(&terminal).expect("terminal modes");
            modes.make_raw();
            rustix::termios::tcsetattr(&terminal, rustix::termios::OptionalActions::Now, &modes)
                .expect("the child enters raw mode");
            rustix::fs::fcntl_setfl(&terminal, rustix::fs::OFlags::NONBLOCK)
                .expect("an absent key fails instead of blocking");
            let mut read = std::fs::File::from(terminal);
            let mut got = [0];
            read.read_exact(&mut got).expect("queued input arrives");
            assert_eq!(got, [wanted]);
        }
    }
}
